function rbase()
    return Distributions.sample([DNA_A, DNA_C, DNA_G, DNA_T])
end

function mutate_base(base::DNA)
    result = rbase()
    while result == base
        result = rbase()
    end
    return result
end

function mutate_seq(seq::DNASeq, n_diffs::Int)
    seq = copy(seq)
    positions = Base.rand(1:length(seq), n_diffs)
    for i in positions
        seq[i] = mutate_base(seq[i])
    end
    return seq
end

function random_codon()
    return (rbase(), rbase(), rbase())
end

function random_seq(n)
    return DNASeq(map(_ -> rbase(), 1:n))
end

# bounds for per-base error probabilities
const MIN_PROB = Prob(1e-10)
const MAX_PROB = Prob(0.5)

"""Add independent noise to each position in vector."""
function jitter_phred_domain(x::Vector{Prob},
                             phred_std::Prob)
    error = randn(length(x)) * phred_std / 10.0
    result = exp10.(log10.(x) + error)
    result[map(a -> a < MIN_PROB, result)] = MIN_PROB
    result[map(a -> a > MAX_PROB, result)] = MAX_PROB
    return result
end

function hmm_sample(sequence::DNASeq,
                    error_p::Vector{Prob},
                    errors::ErrorModel)
    errors = normalize(errors)
    codon = errors.codon_insertion > 0.0 || errors.codon_deletion > 0.0
    if codon && (errors.insertion > 0.0 || errors.deletion > 0.0)
        error("codon and non-codon indels are not both allowed")
    end
    if codon && length(sequence) % 3 != 0
        error("sequence length is not multiple of 3")
    end
    sub_ratio = errors.mismatch
    ins_ratio = errors.insertion
    del_ratio = errors.deletion
    if codon
        ins_ratio = errors.codon_insertion
        del_ratio = errors.codon_deletion
    end
    final_seq = []
    final_error_p = Prob[]
    seqbools = Bool[]
    tbools = Bool[]
    skip = 0
    for i = 1:(length(sequence) + 1)
        p = (i > length(sequence) ? error_p[i - 1] : error_p[i])
        prev_p = (i == 1 ? error_p[1] : error_p[i - 1])
        # insertion between i-1 and i
        max_p = max(p, prev_p)
        ins_p = max_p * ins_ratio
        if codon
            ins_p /= 3.0
        end
        if Base.rand(Bernoulli(ins_p)) == 1
            if codon
                push!(final_seq, random_codon()...)
                push!(final_error_p, collect(Base.Iterators.repeated(max_p, 3))...)
                push!(seqbools, false, false, false)
            else
                push!(final_seq, rbase())
                push!(final_error_p, max_p)
                push!(seqbools, false)
            end
        end
        if i > length(sequence)
            break
        end

        # only skip after insertions, to ensure equal probability of
        # insertion and deletions
        if skip > 0
            skip -= 1
            continue
        end
        # deletion of i
        if codon
            if i > length(sequence) - 2
                del_p = 0.0
            else
                del_p = maximum(error_p[i:i + 2]) * del_ratio / 3.0
            end
        else
            del_p = p * del_ratio
        end
        if Base.rand(Bernoulli(del_p)) == 1
            # skip position i, and possibly the entire codon starting at i
            skip = codon ? 2 : 0
            append!(tbools, fill(false, skip + 1))
        else
            # mutation of position i
            if Base.rand(Bernoulli(p * sub_ratio)) == 1
                push!(final_seq, mutate_base(sequence[i]))
                push!(seqbools, false)
                push!(tbools, false)
            else
                push!(final_seq, sequence[i])
                push!(seqbools, true)
                push!(tbools, true)
            end
            push!(final_error_p, p)
        end
    end
    return DNASeq(final_seq), final_error_p, seqbools, tbools
end

function sample_reference(reference::DNASeq,
                          error_rate::Prob,
                          errors::ErrorModel)
    errors = normalize(errors)
    if errors.insertion > 0.0 || errors.deletion > 0.0
        error("non-codon indels are not allowed in template")
    end
    error_p = error_rate * ones(length(reference))
    template, _, _, _ = hmm_sample(reference, error_p, errors)
    return template
end

function sample_from_template(template::DNASeq,
                              template_error_p::Vector{Prob},
                              errors::ErrorModel,
                              phred_scale::Float64,
                              actual_std::Float64,
                              reported_std::Float64)
    errors = normalize(errors)
    if errors.codon_insertion > 0.0 || errors.codon_deletion > 0.0
        error("codon indels are not allowed in sequences")
    end
    # add noise to simulate measurement error
    d = Exponential(phred_scale)
    base_vector = exp10.((-10.0 * log10.(template_error_p) + rand(d)) / (-10.0))
    jittered_error_p = jitter_phred_domain(base_vector,
                                           actual_std)

    seq, actual_error_p, sbools, tbools = hmm_sample(template,
                                                     jittered_error_p,
                                                     errors)

    # add noise to simulate quality score estimation error
    reported_error_p = jitter_phred_domain(actual_error_p,
                                           reported_std)
    phreds = p_to_phred(reported_error_p)
    return DNASeq(seq), actual_error_p, phreds, sbools, tbools
end

function sample_mixture(nseqs::Tuple{Int,Int}, len::Int, n_diffs::Int;
                        ref_error_rate::Prob=0.1,
                        ref_errors::ErrorModel=ErrorModel(10, 0, 0, 1, 0),
                        error_rate::Prob=0.01,
                        alpha::Float64=0.1,
                        phred_scale::Float64=1.5,
                        actual_std::Float64=3.0,
                        reported_std::Float64=1.0,
                        seq_errors::ErrorModel=ErrorModel(1, 5, 5))
    if len % 3 != 0
        error("Reference length must be a multiple of three")
    end

    template1 = random_seq(len)
    template2 = mutate_seq(template1, n_diffs)
    templates = DNASeq[template1, template2]

    reference = sample_reference(template1,
                                 ref_error_rate,
                                 ref_errors)

    # generate template error rates from four-parameter Beta distribution
    beta = alpha * (error_rate - MAX_PROB) / (MIN_PROB - error_rate)
    error_dist = Beta(alpha, beta)
    template_error_p = rand(error_dist, len) * (MAX_PROB - MIN_PROB) + MIN_PROB

    seqs = DNASeq[]
    actual_error_ps = Vector{Prob}[]
    phreds = Vector{Phred}[]
    seqbools = Vector{Bool}[]
    tbools = Vector{Bool}[]
    for (t, n) in zip(templates, nseqs)
        for i = 1:n
            (seq, actual_error_p, phred, cb,
             db) = sample_from_template(t,
                                        template_error_p,
                                        seq_errors,
                                        phred_scale,
                                        actual_std,
                                        reported_std)
            push!(seqs, seq)
            push!(actual_error_ps, actual_error_p)
            push!(phreds, phred)
            push!(seqbools, cb)
            push!(tbools, db)
        end
    end
    return (DNASeq(reference),
            DNASeq[DNASeq(t) for t in templates],
            template_error_p, seqs, actual_error_ps, phreds,
            seqbools, tbools)
end

function sample(nseqs::Int=3,
                len::Int=90;
                ref_error_rate::Prob=0.1,
                ref_errors::ErrorModel=ErrorModel(10, 0, 0, 1, 0),
                error_rate::Prob=0.01,
                alpha::Float64=0.1,
                phred_scale::Float64=1.5,
                actual_std::Float64=3.0,
                reported_std::Float64=1.0,
                seq_errors::ErrorModel=ErrorModel(1, 5, 5))
    (ref, templates, t_p, seqs, actual,
     phreds, cb, db) = sample_mixture((nseqs, 0), len, 0;
                                      ref_error_rate=ref_error_rate,
                                      ref_errors=ref_errors,
                                      error_rate=error_rate,
                                      alpha=alpha,
                                      phred_scale=phred_scale,
                                      actual_std=actual_std,
                                      reported_std=reported_std,
                                      seq_errors=seq_errors)
    return ref, templates[1], t_p, seqs, actual, phreds, cb, db
end

"""Write template into FASTA and sequences into FASTQ."""
function write_samples(filename, reference, template, template_error, seqs, phreds)
    template_phred = p_to_phred(template_error)
    write_fasta(string(filename, "-reference.fasta"), [reference])
    write_fastq(string(filename, "-template.fastq"), [template], Vector{Phred}[template_phred])
    write_fastq(string(filename, "-sequences.fastq"), seqs, phreds)
end

"""Read template from FASTA and sequences from FASTQ."""
function read_samples(filename)
    reference = read_fasta(string(filename, "-reference.fasta"))[1]
    template_seqs, template_phreds = read_fastq(string(filename, "-template.fastq"))
    template = template_seqs[1]
    template_error = phred_to_p(template_phreds[1])
    seqs, phreds = read_fastq(string(filename, "-sequences.fastq"))
    return reference, template, template_error, seqs, phreds
end
