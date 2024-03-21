struct TRAINSET{}
    input_data::Vector{ODEProblem}
    output_data::Array
    isu0::Bool
end

function TRAINSET(input_data, output_data; isu0 = false)
    TRAINSET(input_data, output_data, isu0)
end

mutable struct PINOPhi{C, T, U, S}
    chain::C
    t0::T
    u0::U
    st::S
    function PINOPhi(chain::Lux.AbstractExplicitLayer, t0, u0, st)
        new{typeof(chain), typeof(t0), typeof(u0), typeof(st)}(chain, t0, u0, st)
    end
end

struct PINOsolution{}
    predict::Array
    res::SciMLBase.OptimizationSolution
    phi::PINOPhi
    input_data_set::Array
end

abstract type PINOPhases end
struct OperatorLearning <: PINOPhases
    is_data_loss::Bool
    is_physics_loss::Bool
end
function OperatorLearning(; is_data_loss = true, is_physics_loss = true)
    OperatorLearning(is_data_loss, is_physics_loss)
end
struct EquationSolving <: PINOPhases
    pino_solution::PINOsolution
end

"""
   PINOODE(chain,
    OptimizationOptimisers.Adam(0.1),
    train_set,
    is_data_loss =true,
    is_physics_loss =true,
    init_params,
    #TODO update docstring
    kwargs...)

The method is that combine training data and physics constraints
to learn the solution operator of a given family of parametric Ordinary Differential Equations (ODE).

## Positional Arguments
* `chain`: A neural network architecture, defined as a `Lux.AbstractExplicitLayer` or `Flux.Chain`.
          `Flux.Chain` will be converted to `Lux` using `Lux.transform`.
* `opt`: The optimizer to train the neural network.
* `train_set`: Contains 'input data' - sr of parameters 'a' and output data - set of solutions
 u(t){a} corresponding initial conditions 'u0'.

## Keyword Arguments
* `is_data_loss` Includes or off a loss function for training on the data set.
* `is_physics_loss`: Includes or off loss function training on physics-informed approach.
* `init_params`: The initial parameter of the neural network. By default, this is `nothing`
  which thus uses the random initialization provided by the neural network library.
* `kwargs`: Extra keyword arguments are splatted to the Optimization.jl `solve` call.

## References
Zongyi Li "Physics-Informed Neural Operator for Learning Partial Differential Equations"
"""
struct PINOODE{C, O, P, K} <: DiffEqBase.AbstractODEAlgorithm
    chain::C
    opt::O
    train_set::TRAINSET
    pino_phase::PINOPhases
    init_params::P
    kwargs::K
end

function PINOODE(chain,
        opt,
        train_set,
        pino_phase;
        init_params = nothing,
        kwargs...)
    #TODO fnn transform check
    !(chain isa Lux.AbstractExplicitLayer) && (chain = Lux.transform(chain))
    PINOODE(chain, opt, train_set, pino_phase, init_params, kwargs)
end

function generate_pino_phi_θ(chain::Lux.AbstractExplicitLayer,
        t0,
        u0,
        init_params)
    θ, st = Lux.setup(Random.default_rng(), chain)
    if init_params === nothing
        init_params = ComponentArrays.ComponentArray(θ)
    else
        init_params = ComponentArrays.ComponentArray(init_params)
    end
    PINOPhi(chain, t0, u0, st), init_params
end

function (f::PINOPhi{C, T, U})(t::AbstractArray,
        θ) where {C <: Lux.AbstractExplicitLayer, T, U}
    y, st = f.chain(adapt(parameterless_type(ComponentArrays.getdata(θ)), t), θ, f.st)
    ChainRulesCore.@ignore_derivatives f.st = st
    ts = adapt(parameterless_type(ComponentArrays.getdata(θ)), t[1:size(y)[1], :, :])
    f_ = adapt(parameterless_type(ComponentArrays.getdata(θ)), f.u0)
    f_ .+ (ts .- f.t0) .* y
end

function dfdx_rand_matrix(phi::PINOPhi, t::AbstractArray, θ)
    ε_ = sqrt(eps(eltype(t)))
    d = Normal{eltype(t)}(0.0f0, ε_)
    size_ = size(t) .- (1, 0, 0)
    eps_ = ε_ .+ rand(d, size_) .* ε_
    zeros_ = zeros(eltype(t), size_)
    ε = cat(eps_, zeros_, dims = 1)
    (phi(t .+ ε, θ) - phi(t, θ)) ./ sqrt(eps(eltype(t)))
end

function dfdx(phi::PINOPhi, t::AbstractArray, θ)
    ε = [sqrt(eps(eltype(t))), zeros(eltype(t), size(t)[1] - 1)...]
    (phi(t .+ ε, θ) - phi(t, θ)) ./ sqrt(eps(eltype(t)))
end

function l₂loss(𝐲̂, 𝐲)
    feature_dims = 2:(ndims(𝐲) - 1)
    loss = sum(.√(sum(abs2, 𝐲̂ - 𝐲, dims = feature_dims)))
    y_norm = sum(.√(sum(abs2, 𝐲, dims = feature_dims)))
    return loss / y_norm
end

function physics_loss(phi::PINOPhi{C, T, U},
        θ,
        ts::AbstractArray,
        train_set::TRAINSET,
        input_data_set) where {C, T, U}
    prob_set, _ = train_set.input_data, train_set.output_data
    f = prob_set[1].f
    p = prob_set[1].p
    out_ = phi(input_data_set, θ)
    ts = adapt(parameterless_type(ComponentArrays.getdata(θ)), ts)
    if train_set.isu0 == true
        fs = f.f.(out_, p, ts)
    else
        ps = [prob.p for prob in prob_set]
        if p isa Number
            fs = cat(
                [f.f.(out_[:, :, [i]], p, ts) for (i, p) in enumerate(ps)]..., dims = 3)
        elseif p isa Vector
            fs = cat(
                [reduce(
                     hcat, [f.f(out_[:, j, [i]], p, ts) for j in axes(out_[:, :, [i]], 2)])
                 for (i, p) in enumerate(ps)]...,
                dims = 3)
        else
            error("p should be a number or a vector")
        end
    end
    l₂loss(dfdx(phi, input_data_set, θ), fs)
end

function data_loss(phi::PINOPhi{C, T, U},
        θ,
        train_set::TRAINSET,
        input_data_set) where {C, T, U}
    _, output_data = train_set.input_data, train_set.output_data
    output_data = adapt(parameterless_type(ComponentArrays.getdata(θ)), output_data)
    l₂loss(phi(input_data_set, θ), output_data)
end

function generate_data(ts, prob_set::Vector{ODEProblem}, isu0)
    batch_size = size(prob_set)[1]
    instances_size = size(ts)[2]
    dims = isu0 ? length(prob_set[1].u0) + 1 : length(prob_set[1].p) + 1
    input_data_set = Array{Float32, 3}(undef, dims, instances_size, batch_size)
    for (i, prob) in enumerate(prob_set)
        u0 = prob.u0
        p = prob.p
        # f = prob.f
        if isu0 == true
            in_ = reduce(vcat, [ts, fill(u0, 1, size(ts)[2], 1)])
        else
            if p isa Number
                in_ = reduce(vcat, [ts, fill(p, 1, size(ts)[2], 1)])
            elseif p isa Vector
                inner = reduce(vcat, [ts, reduce(hcat, fill(p, 1, size(ts)[2], 1))])
                in_ = reshape(inner, size(inner)..., 1)
            else
                error("p should be a number or a vector")
            end
        end
        input_data_set[:, :, i] = in_
    end
    input_data_set
end

function generate_loss(
        phi::PINOPhi{C, T, U}, train_set::TRAINSET, input_data_set, ts,
        pino_phase::OperatorLearning) where {
        C, T, U}
    is_data_loss, is_physics_loss = pino_phase.is_data_loss, pino_phase.is_physics_loss
    function loss(θ, _)
        if is_data_loss
            data_loss(phi, θ, train_set, input_data_set)
        elseif is_physics_loss
            physics_loss(phi, θ, ts, train_set, input_data_set)
        elseif is_data_loss && is_physics_loss
            data_loss(phi, θ, train_set, input_data_set) +
            physics_loss(phi, θ, ts, train_set, input_data_set)
        else
            error("data loss or physics loss should be true")
        end
    end
    return loss
end

function finetune_loss(phi::PINOPhi{C, T, U},
        θ,
        train_set::TRAINSET,
        input_data_set,
        pino_phase::EquationSolving) where {C, T, U}
    _, output_data = train_set.input_data, train_set.output_data
    output_data = adapt(parameterless_type(ComponentArrays.getdata(θ)), output_data)
    pino_solution = pino_phase.pino_solution
    learned_operator = pino_solution.phi
    predict = learned_operator(input_data_set, pino_solution.res.u)
    l₂loss(phi(input_data_set, θ), predict)
end

function generate_loss(
        phi::PINOPhi{C, T, U}, train_set::TRAINSET, input_data_set, ts,
        pino_phase::EquationSolving) where {
        C, T, U}
    a = 1 / 100
    function loss(θ, _)
        physics_loss(phi, θ, ts, train_set, input_data_set) +
        a * finetune_loss(phi, θ, train_set, input_data_set, pino_phase)
    end
    return loss
end

function DiffEqBase.__solve(prob::DiffEqBase.AbstractODEProblem,
        alg::PINOODE,
        args...;
        # dt = nothing,
        abstol = 1.0f-6,
        reltol = 1.0f-3,
        verbose = false,
        saveat = nothing,
        maxiters = nothing)
    tspan = prob.tspan
    t0, t_end = tspan[1], tspan[2]
    u0 = prob.u0
    p = prob.p
    # f = prob.f
    # param_estim = alg.param_estim

    chain = alg.chain
    opt = alg.opt
    init_params = alg.init_params
    pino_phase = alg.pino_phase
    # mapping between functional space of some vararible 'a' of equation (for example initial
    # condition {u(t0 x)} or parameter p) and solution of equation u(t)
    train_set = alg.train_set

    !(chain isa Lux.AbstractExplicitLayer) &&
        error("Only Lux.AbstractExplicitLayer neural networks are supported")

    instances_size = size(train_set.output_data)[2]
    range_ = range(t0, stop = t_end, length = instances_size)
    ts = reshape(collect(range_), 1, instances_size)
    prob_set, output_set = train_set.input_data, train_set.output_data
    isu0 = train_set.isu0
    input_data_set = generate_data(ts, prob_set, isu0)
    # input_data_set =  if pino_phase == EquationSolving
    #     generate_data(ts, [prob], isu0)
    # elseif pino_phase == OperatorLearning
    #     generate_data(ts, prob_set, isu0)
    # else
    #     error("pino_phase should be EquationSolving or OperatorLearning")
    # end

    if isu0 #TODO remove the block
        u0 = input_data_set[2:end, :, :]
    else
        u0 = prob.u0
    end
    phi, init_params = generate_pino_phi_θ(chain, t0, u0, init_params)
    init_params = ComponentArrays.ComponentArray(init_params)

    isinplace(prob) &&
        throw(error("The PINOODE solver only supports out-of-place ODE definitions, i.e. du=f(u,p,t)."))

    try
        phi(input_data_set, init_params)
    catch err
        if isa(err, DimensionMismatch)
            throw(DimensionMismatch("Dimensions of input data and chain should match"))
        else
            throw(err)
        end
    end

    if pino_phase isa EquationSolving
        #TODO bad code rewrite,the parameter must uniquely match the index
        #TODO doenst need TRAINSET for EquationSolving
        find(as, a) = findfirst(x -> isapprox(x.p, a.p), as)
        index = find(prob_set, prob)
        input_data_set = input_data_set[:, :, [index]]
        train_set = TRAINSET(prob_set[index:index], output_set[:, :, [index]], isu0)
        total_loss = generate_loss(phi, train_set, input_data_set, ts, pino_phase)
    elseif pino_phase isa OperatorLearning
        total_loss = generate_loss(phi, train_set, input_data_set, ts, pino_phase)
    else
        error("pino_phase should be EquationSolving or OperatorLearning")
    end

    # Optimization Algo for Training Strategies
    opt_algo = Optimization.AutoZygote()

    # Creates OptimizationFunction Object from total_loss
    optf = OptimizationFunction(total_loss, opt_algo)

    iteration = 0
    callback = function (p, l)
        iteration += 1
        verbose && println("Current loss is: $l, Iteration: $iteration")
        l < abstol
    end

    optprob = OptimizationProblem(optf, init_params)
    res = solve(optprob, opt; callback, maxiters, alg.kwargs...)
    predict = phi(input_data_set, res.u)
    PINOsolution(predict, res, phi, input_data_set)
end
