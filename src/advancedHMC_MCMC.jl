mutable struct LogTargetDensity{C, S, ST <: AbstractTrainingStrategy, I,
    P <: Vector{<:Distribution},
    D <:
    Union{Vector{Nothing}, Vector{<:Vector{<:AbstractFloat}}},
}
    dim::Int
    prob::DiffEqBase.ODEProblem
    chain::C
    st::S
    strategy::ST
    dataset::D
    priors::P
    phystd::Vector{Float64}
    l2std::Vector{Float64}
    autodiff::Bool
    physdt::Float64
    extraparams::Int
    init_params::I

    function LogTargetDensity(dim, prob, chain::Optimisers.Restructure, st, strategy,
        dataset,
        priors, phystd, l2std, autodiff, physdt, extraparams,
        init_params::AbstractVector)
        new{
            typeof(chain),
            Nothing,
            typeof(strategy),
            typeof(init_params),
            typeof(priors),
            typeof(dataset),
        }(dim,
            prob,
            chain,
            nothing, strategy,
            dataset,
            priors,
            phystd,
            l2std,
            autodiff,
            physdt,
            extraparams,
            init_params)
    end
    function LogTargetDensity(dim, prob, chain::Lux.AbstractExplicitLayer, st, strategy,
        dataset,
        priors, phystd, l2std, autodiff, physdt, extraparams,
        init_params::NamedTuple)
        new{
            typeof(chain),
            typeof(st),
            typeof(strategy),
            typeof(init_params),
            typeof(priors),
            typeof(dataset),
        }(dim,
            prob,
            chain, st, strategy,
            dataset, priors,
            phystd, l2std,
            autodiff,
            physdt,
            extraparams,
            init_params)
    end
end

"""
cool function to convert parameter's vector to ComponentArray of parameters (for Lux Chain: vector of samples -> Lux ComponentArrays)
"""
function vector_to_parameters(ps_new::AbstractVector, ps::NamedTuple)
    @assert length(ps_new) == Lux.parameterlength(ps)
    i = 1
    function get_ps(x)
        z = reshape(view(ps_new, i:(i + length(x) - 1)), size(x))
        i += length(x)
        return z
    end
    return Functors.fmap(get_ps, ps)
end

function LogDensityProblems.logdensity(Tar::LogTargetDensity, θ)
    return physloglikelihood(Tar, θ) + priorweights(Tar, θ) + L2LossData(Tar, θ)
    #  +  L2loss2(Tar, θ)
end

LogDensityProblems.dimension(Tar::LogTargetDensity) = Tar.dim

function LogDensityProblems.capabilities(::LogTargetDensity)
    LogDensityProblems.LogDensityOrder{1}()
end

# suggested extra loss function
function L2loss2(Tar::LogTargetDensity, θ)
    f = Tar.prob.f

    # parameter estimation chosen or not
    if Tar.extraparams > 0
        dataset, deri_sol = Tar.dataset
        # deri_sol = deri_sol'
        autodiff = Tar.autodiff

        # # Timepoints to enforce Physics
        # dataset = Array(reduce(hcat, dataset)')
        # t = dataset[end, :]
        # û = dataset[1:(end - 1), :]

        # ode_params = Tar.extraparams == 1 ?
        #              θ[((length(θ) - Tar.extraparams) + 1):length(θ)][1] :
        #              θ[((length(θ) - Tar.extraparams) + 1):length(θ)]

        # if length(û[:, 1]) == 1
        #     physsol = [f(û[:, i][1],
        #         ode_params,
        #         t[i])
        #                for i in 1:length(û[1, :])]
        # else
        #     physsol = [f(û[:, i],
        #         ode_params,
        #         t[i])
        #                for i in 1:length(û[1, :])]
        # end
        # #form of NN output matrix output dim x n
        # deri_physsol = reduce(hcat, physsol)

        # > for perfect deriv(basically gradient matching in case of an ODEFunction)
        # in case of PDE or general ODE we would want to reduce residue of f(du,u,p,t)
        # if length(û[:, 1]) == 1
        #     deri_sol = [f(û[:, i][1],
        #         Tar.prob.p,
        #         t[i])
        #                 for i in 1:length(û[1, :])]
        # else
        #     deri_sol = [f(û[:, i],
        #         Tar.prob.p,
        #         t[i])
        #                 for i in 1:length(û[1, :])]
        # end
        # deri_sol = reduce(hcat, deri_sol) 
        # deri_sol = reduce(hcat, derivatives)

        # Timepoints to enforce Physics 
        t = dataset[end]
        u1 = dataset[2]
        û = dataset[1]
        # Tar(t, θ[1:(length(θ) - Tar.extraparams)])'
        #  

        nnsol = NNodederi(Tar, t, θ[1:(length(θ) - Tar.extraparams)], autodiff)

        ode_params = Tar.extraparams == 1 ?
                     θ[((length(θ) - Tar.extraparams) + 1):length(θ)][1] :
                     θ[((length(θ) - Tar.extraparams) + 1):length(θ)]

        if length(Tar.prob.u0) == 1
            physsol = [f(û[i],
                ode_params,
                t[i])
                       for i in 1:length(û[:, 1])]
        else
            physsol = [f([û[i], u1[i]],
                ode_params,
                t[i])
                       for i in 1:length(û[:, 1])]
        end
        #form of NN output matrix output dim x n 
        deri_physsol = reduce(hcat, physsol)

        # if length(Tar.prob.u0) == 1
        #     nnsol = [f(û[i],
        #         Tar.prob.p,
        #         t[i])
        #              for i in 1:length(û[:, 1])]
        # else
        #     nnsol = [f([û[i], u1[i]],
        #         Tar.prob.p,
        #         t[i])
        #              for i in 1:length(û[:, 1])]
        # end
        # form of NN output matrix output dim x n
        # nnsol = reduce(hcat, nnsol)

        # > Instead of dataset gradients trying NN derivatives with dataset collocation 
        # # convert to matrix as nnsol  

        physlogprob = 0
        for i in 1:length(Tar.prob.u0)
            # can add phystd[i] for u[i] 
            physlogprob += logpdf(MvNormal(deri_physsol[i, :],
                    LinearAlgebra.Diagonal(map(abs2,
                        (Tar.l2std[i] * 4.0) .*
                        ones(length(nnsol[i, :]))))),
                nnsol[i, :])
        end
        return physlogprob
    else
        return 0
    end
end

# PDE(DU,U,P,T)=0

# Derivated via Central Diff
# function calculate_derivatives2(dataset)
#     x̂, time = dataset
#     num_points = length(x̂)
#     # Initialize an array to store the derivative values.
#     derivatives = similar(x̂)

#     for i in 2:(num_points - 1)
#         # Calculate the first-order derivative using central differences.
#         Δt_forward = time[i + 1] - time[i]
#         Δt_backward = time[i] - time[i - 1]

#         derivative = (x̂[i + 1] - x̂[i - 1]) / (Δt_forward + Δt_backward)

#         derivatives[i] = derivative
#     end

#     # Derivatives at the endpoints can be calculated using forward or backward differences.
#     derivatives[1] = (x̂[2] - x̂[1]) / (time[2] - time[1])
#     derivatives[end] = (x̂[end] - x̂[end - 1]) / (time[end] - time[end - 1])
#     return derivatives
# end

function calderivatives(prob, dataset)
    chainflux = Flux.Chain(Flux.Dense(1, 8, tanh), Flux.Dense(8, 8, tanh),
        Flux.Dense(8, 2)) |> Flux.f64
    # chainflux = Flux.Chain(Flux.Dense(1, 7, tanh), Flux.Dense(7, 1)) |> Flux.f64
    function loss(x, y)
        # sum(Flux.mse.(prob.u0[1] .+ (prob.tspan[2] .- x)' .* chainflux(x)[1, :], y[1]) +
        #     Flux.mse.(prob.u0[2] .+ (prob.tspan[2] .- x)' .* chainflux(x)[2, :], y[2]))
        # sum(Flux.mse.(prob.u0[1] .+ (prob.tspan[2] .- x)' .* chainflux(x)[1, :], y[1]))
        sum(Flux.mse.(chainflux(x), y))
    end
    optimizer = Flux.Optimise.ADAM(0.01)
    epochs = 3000
    for epoch in 1:epochs
        Flux.train!(loss,
            Flux.params(chainflux),
            [(dataset[end]', dataset[1:(end - 1)])],
            optimizer)
    end

    # A1 = (prob.u0' .+
    #   (prob.tspan[2] .- (dataset[end]' .+ sqrt(eps(eltype(Float64)))))' .*
    #   chainflux(dataset[end]' .+ sqrt(eps(eltype(Float64))))')

    # A2 = (prob.u0' .+
    #       (prob.tspan[2] .- (dataset[end]'))' .*
    #       chainflux(dataset[end]')')

    A1 = chainflux(dataset[end]' .+ sqrt(eps(eltype(dataset[end][1]))))
    A2 = chainflux(dataset[end]')

    gradients = (A2 .- A1) ./ sqrt(eps(eltype(dataset[end][1])))

    return gradients
end

function calculate_derivatives(dataset)

    # u = dataset[1]
    # u1 = dataset[2]
    # t = dataset[end]
    # # control points
    # n = Int(floor(length(t) / 10))
    # # spline for datasetvalues(solution) 
    # # interp = BSplineApprox(u, t, 4, 10, :Uniform, :Uniform)
    # interp = CubicSpline(u, t)
    # interp1 = CubicSpline(u1, t)
    # # derrivatives interpolation
    # dx = t[2] - t[1]
    # time = collect(t[1]:dx:t[end])
    # smoothu = [interp(i) for i in time]
    # smoothu1 = [interp1(i) for i in time]
    # # derivative of the spline (must match function derivative) 
    # û = tvdiff(smoothu, 20, 0.5, dx = dx, ε = 1)
    # û1 = tvdiff(smoothu1, 20, 0.5, dx = dx, ε = 1)
    # # tvdiff(smoothu, 100, 0.035, dx = dx, ε = 1)
    # # FDM
    # # û1 = diff(u) / dx
    # # dataset[1] and smoothu are almost equal(rounding errors)
    # return [û, û1] 

end

"""
L2 loss loglikelihood(needed for ODE parameter estimation)
"""
function L2LossData(Tar::LogTargetDensity, θ)
    dataset = Tar.dataset
    # check if dataset is provided
    if dataset isa Vector{Nothing} || Tar.extraparams == 0
        return 0
    else
        # matrix(each row corresponds to vector u's rows)
        nn = Tar(dataset[end], θ[1:(length(θ) - Tar.extraparams)])

        L2logprob = 0
        for i in 1:length(Tar.prob.u0)
            # for u[i] ith vector must be added to dataset,nn[1,:] is the dx in lotka_volterra
            L2logprob += logpdf(MvNormal(nn[i, :],
                    LinearAlgebra.Diagonal(map(abs2,
                        (Tar.l2std[i] * 0.5) .*
                        ones(length(dataset[i]))))),
                dataset[i])
        end
        return L2logprob
    end
end

"""
physics loglikelihood over problem timespan + dataset timepoints
"""
function physloglikelihood(Tar::LogTargetDensity, θ)
    f = Tar.prob.f
    p = Tar.prob.p
    tspan = Tar.prob.tspan
    autodiff = Tar.autodiff
    strategy = Tar.strategy

    # parameter estimation chosen or not
    if Tar.extraparams > 0
        ode_params = Tar.extraparams == 1 ?
                     θ[((length(θ) - Tar.extraparams) + 1):length(θ)][1] :
                     θ[((length(θ) - Tar.extraparams) + 1):length(θ)]
    else
        ode_params = p == SciMLBase.NullParameters() ? [] : p
    end

    return getlogpdf(strategy, Tar, f, autodiff, tspan, ode_params, θ)
end

function getlogpdf(strategy::GridTraining, Tar::LogTargetDensity, f, autodiff::Bool,
    tspan,
    ode_params, θ)
    if Tar.dataset isa Vector{Nothing}
        t = collect(eltype(strategy.dx), tspan[1]:(strategy.dx):tspan[2])
    else
        t = vcat(collect(eltype(strategy.dx), tspan[1]:(strategy.dx):tspan[2]),
            Tar.dataset[end])
    end

    sum(innerdiff(Tar, f, autodiff, t, θ,
        ode_params))
end

function getlogpdf(strategy::StochasticTraining,
    Tar::LogTargetDensity,
    f,
    autodiff::Bool,
    tspan,
    ode_params,
    θ)
    if Tar.dataset isa Vector{Nothing}
        t = [(tspan[2] - tspan[1]) * rand() + tspan[1] for i in 1:(strategy.points)]
    else
        t = vcat([(tspan[2] - tspan[1]) * rand() + tspan[1] for i in 1:(strategy.points)],
            Tar.dataset[end])
    end

    sum(innerdiff(Tar, f, autodiff, t, θ,
        ode_params))
end

function getlogpdf(strategy::QuadratureTraining, Tar::LogTargetDensity, f,
    autodiff::Bool,
    tspan,
    ode_params, θ)
    function integrand(t::Number, θ)
        innerdiff(Tar, f, autodiff, [t], θ, ode_params)
    end
    intprob = IntegralProblem(integrand, tspan[1], tspan[2], θ; nout = length(Tar.prob.u0))
    # add dataset logpdf?
    sol = solve(intprob, QuadGKJL(); abstol = strategy.abstol, reltol = strategy.reltol)
    sum(sol.u)
end

function getlogpdf(strategy::WeightedIntervalTraining, Tar::LogTargetDensity, f,
    autodiff::Bool,
    tspan,
    ode_params, θ)
    minT = tspan[1]
    maxT = tspan[2]

    weights = strategy.weights ./ sum(strategy.weights)

    N = length(weights)
    points = strategy.points

    difference = (maxT - minT) / N

    data = Float64[]
    for (index, item) in enumerate(weights)
        temp_data = rand(1, trunc(Int, points * item)) .* difference .+ minT .+
                    ((index - 1) * difference)
        data = append!(data, temp_data)
    end

    if Tar.dataset isa Vector{Nothing}
        t = data
    else
        t = vcat(data,
            Tar.dataset[end])
    end

    sum(innerdiff(Tar, f, autodiff, t, θ,
        ode_params))
end

"""
MvNormal likelihood at each `ti` in time `t` for ODE collocation residue with NN with parameters θ 
"""
function innerdiff(Tar::LogTargetDensity, f, autodiff::Bool, t::AbstractVector, θ,
    ode_params)

    # Tar used for phi and LogTargetDensity object attributes access
    out = Tar(t, θ[1:(length(θ) - Tar.extraparams)])

    # # reject samples case(write clear reason why)
    if any(isinf, out[:, 1]) || any(isinf, ode_params)
        return -Inf
    end

    # this is a vector{vector{dx,dy}}(handle case single u(float passed))
    if length(out[:, 1]) == 1
        physsol = [f(out[:, i][1],
            ode_params,
            t[i])
                   for i in 1:length(out[1, :])]
    else
        physsol = [f(out[:, i],
            ode_params,
            t[i])
                   for i in 1:length(out[1, :])]
    end
    physsol = reduce(hcat, physsol)

    nnsol = NNodederi(Tar, t, θ[1:(length(θ) - Tar.extraparams)], autodiff)

    vals = nnsol .- physsol

    # N dimensional vector if N outputs for NN(each row has logpdf of i[i] where u is vector of dependant variables)
    return [logpdf(MvNormal(vals[i, :],
            LinearAlgebra.Diagonal(map(abs2,
                Tar.phystd[i] .*
                ones(length(vals[i, :]))))),
        zeros(length(vals[i, :]))) for i in 1:length(Tar.prob.u0)]
end

"""
prior logpdf for NN parameters + ODE constants
"""
function priorweights(Tar::LogTargetDensity, θ)
    allparams = Tar.priors
    # nn weights
    nnwparams = allparams[1]

    if Tar.extraparams > 0
        # Vector of ode parameters priors
        invpriors = allparams[2:end]

        invlogpdf = sum(logpdf(invpriors[length(θ) - i + 1], θ[i])
                        for i in (length(θ) - Tar.extraparams + 1):length(θ); init = 0.0)

        return (invlogpdf
                +
                logpdf(nnwparams, θ[1:(length(θ) - Tar.extraparams)]))
    else
        return logpdf(nnwparams, θ)
    end
end

function generate_Tar(chain::Lux.AbstractExplicitLayer, init_params)
    θ, st = Lux.setup(Random.default_rng(), chain)
    return init_params, chain, st
end

function generate_Tar(chain::Lux.AbstractExplicitLayer, init_params::Nothing)
    θ, st = Lux.setup(Random.default_rng(), chain)
    return θ, chain, st
end

function generate_Tar(chain::Flux.Chain, init_params)
    θ, re = Flux.destructure(chain)
    return init_params, re, nothing
end

function generate_Tar(chain::Flux.Chain, init_params::Nothing)
    θ, re = Flux.destructure(chain)
    # find_good_stepsize,phasepoint takes only float64
    return θ, re, nothing
end

"""
nn OUTPUT AT t,θ ~ phi(t,θ)
"""
function (f::LogTargetDensity{C, S})(t::AbstractVector,
    θ) where {C <: Optimisers.Restructure, S}
    f.prob.u0 .+ (t' .- f.prob.tspan[1]) .* f.chain(θ)(adapt(parameterless_type(θ), t'))
end

function (f::LogTargetDensity{C, S})(t::AbstractVector,
    θ) where {C <: Lux.AbstractExplicitLayer, S}
    θ = vector_to_parameters(θ, f.init_params)
    y, st = f.chain(adapt(parameterless_type(ComponentArrays.getdata(θ)), t'), θ, f.st)
    ChainRulesCore.@ignore_derivatives f.st = st
    f.prob.u0 .+ (t' .- f.prob.tspan[1]) .* y
end

function (f::LogTargetDensity{C, S})(t::Number,
    θ) where {C <: Optimisers.Restructure, S}
    #  must handle paired odes hence u0 broadcasted
    f.prob.u0 .+ (t - f.prob.tspan[1]) * f.chain(θ)(adapt(parameterless_type(θ), [t]))
end

function (f::LogTargetDensity{C, S})(t::Number,
    θ) where {C <: Lux.AbstractExplicitLayer, S}
    θ = vector_to_parameters(θ, f.init_params)
    y, st = f.chain(adapt(parameterless_type(ComponentArrays.getdata(θ)), [t]), θ, f.st)
    ChainRulesCore.@ignore_derivatives f.st = st
    f.prob.u0 .+ (t .- f.prob.tspan[1]) .* y
end

"""
similar to ode_dfdx() in NNODE/ode_solve.jl
"""
function NNodederi(phi::LogTargetDensity, t::AbstractVector, θ, autodiff::Bool)
    if autodiff
        hcat(ForwardDiff.derivative.(ti -> phi(ti, θ), t)...)
    else
        (phi(t .+ sqrt(eps(eltype(t))), θ) - phi(t, θ)) ./ sqrt(eps(eltype(t)))
    end
end

function kernelchoice(Kernel, max_depth, Δ_max, n_leapfrog, δ, λ)
    if Kernel == HMC
        Kernel(n_leapfrog)
    elseif Kernel == HMCDA
        Kernel(δ, λ)
    else
        Kernel(δ, max_depth = max_depth, Δ_max = Δ_max)
    end
end

function integratorchoice(Integrator, initial_ϵ, jitter_rate,
    tempering_rate)
    if Integrator == JitteredLeapfrog
        Integrator(initial_ϵ, jitter_rate)
    elseif Integrator == TemperedLeapfrog
        Integrator(initial_ϵ, tempering_rate)
    else
        Integrator(initial_ϵ)
    end
end

function adaptorchoice(Adaptor, mma, ssa)
    if Adaptor != AdvancedHMC.NoAdaptation()
        Adaptor(mma, ssa)
    else
        AdvancedHMC.NoAdaptation()
    end
end

"""
```julia
ahmc_bayesian_pinn_ode(prob, chain; strategy = GridTraining,
                    dataset = [nothing],init_params = nothing, 
                    draw_samples = 1000, physdt = 1 / 20.0f0,l2std = [0.05],
                    phystd = [0.05], priorsNNw = (0.0, 2.0),
                    param = [],nchains = 1,autodiff = false, Kernel = HMC,
                    Integrator = Leapfrog, Adaptor = StanHMCAdaptor,
                    targetacceptancerate = 0.8, Metric = DiagEuclideanMetric,
                    jitter_rate = 3.0, tempering_rate = 3.0, max_depth = 10,
                    Δ_max = 1000, n_leapfrog = 10, δ = 0.65, λ = 0.3,
                    progress = false,verbose = false)
```
!!! warn

    Note that ahmc_bayesian_pinn_ode() only supports ODEs which are written in the out-of-place form, i.e.
    `du = f(u,p,t)`, and not `f(du,u,p,t)`. If not declared out-of-place, then the ahmc_bayesian_pinn_ode()
    will exit with an error.

## Example
linear = (u, p, t) -> -u / p[1] + exp(t / p[2]) * cos(t)
tspan = (0.0, 10.0)
u0 = 0.0
p = [5.0, -5.0]
prob = ODEProblem(linear, u0, tspan, p)

# CREATE DATASET (Necessity for accurate Parameter estimation)
sol = solve(prob, Tsit5(); saveat = 0.05)
u = sol.u[1:100]
time = sol.t[1:100]

# dataset and BPINN create
x̂ = collect(Float64, Array(u) + 0.05 * randn(size(u)))
dataset = [x̂, time]

chainflux1 = Flux.Chain(Flux.Dense(1, 5, tanh), Flux.Dense(5, 5, tanh), Flux.Dense(5, 1)

# simply solving ode here hence better to not pass dataset(uses ode params specified in prob)
fh_mcmc_chainflux1, fhsamplesflux1, fhstatsflux1 = ahmc_bayesian_pinn_ode(prob,chainflux1,
                                                                          dataset = dataset,
                                                                          draw_samples = 1500,
                                                                          l2std = [0.05],
                                                                          phystd = [0.05],
                                                                          priorsNNw = (0.0,3.0))

# solving ode + estimating parameters hence dataset needed to optimize parameters upon + Pior Distributions for ODE params
fh_mcmc_chainflux2, fhsamplesflux2, fhstatsflux2 = ahmc_bayesian_pinn_ode(prob,chainflux1,
                                                                          dataset = dataset,
                                                                          draw_samples = 1500,
                                                                          l2std = [0.05],
                                                                          phystd = [0.05],
                                                                          priorsNNw = (0.0,3.0),
                                                                          param = [Normal(6.5,0.5),Normal(-3,0.5)])

## NOTES 
Dataset is required for accurate Parameter estimation + solving equations
Incase you are only solving the Equations for solution, do not provide dataset

## Positional Arguments
* `prob`: DEProblem(out of place and the function signature should be f(u,p,t)
* `chain`: Lux/Flux Neural Netork which would be made the Bayesian PINN

## Keyword Arguments
* `strategy`: The training strategy used to choose the points for the evaluations. By default GridTraining is used with given physdt discretization.
* `dataset`: Vector containing Vectors of corresponding u,t values 
* `init_params`: intial parameter values for BPINN (ideally for multiple chains different initializations preferred)
* `nchains`: number of chains you want to sample (random initialisation of params by default)
* `draw_samples`: number of samples to be drawn in the MCMC algorithms (warmup samples are ~2/3 of draw samples)
* `l2std`: standard deviation of BPINN predicition against L2 losses/Dataset
* `phystd`: standard deviation of BPINN predicition against Chosen Underlying ODE System
* `priorsNNw`: Vector of [mean, std] for BPINN parameter. Weights and Biases of BPINN are Normal Distributions by default
* `param`: Vector of chosen ODE parameters Distributions in case of Inverse problems.
* `autodiff`: Boolean Value for choice of Derivative Backend(default is numerical)
* `physdt`: Timestep for approximating ODE in it's Time domain. (1/20.0 by default)

# AHMC.jl is still developing convenience structs so might need changes on new releases.
* `Kernel`: Choice of MCMC Sampling Algorithm (AdvancedHMC.jl implemenations HMC/NUTS/HMCDA)
* `targetacceptancerate`: Target percentage(in decimal) of iterations in which the proposals were accepted(0.8 by default)
* `Integrator(jitter_rate, tempering_rate), Metric, Adaptor`: https://turinglang.org/AdvancedHMC.jl/stable/
* `max_depth`: Maximum doubling tree depth (NUTS)
* `Δ_max`: Maximum divergence during doubling tree (NUTS)
* `n_leapfrog`: number of leapfrog steps for HMC
* `δ`: target acceptance probability for NUTS/HMCDA
* `λ`: target trajectory length for HMCDA
* `progress`: controls whether to show the progress meter or not.
* `verbose`: controls the verbosity. (Sample call args in AHMC)

"""

"""
dataset would be (x̂,t)
priors: pdf for W,b + pdf for ODE params
"""
function ahmc_bayesian_pinn_ode(prob::DiffEqBase.ODEProblem, chain;
    strategy = GridTraining, dataset = [nothing],
    init_params = nothing, draw_samples = 1000,
    physdt = 1 / 20.0, l2std = [0.05],
    phystd = [0.05], priorsNNw = (0.0, 2.0),
    param = [], nchains = 1, autodiff = false,
    Kernel = HMC, Integrator = Leapfrog,
    Adaptor = StanHMCAdaptor, targetacceptancerate = 0.8,
    Metric = DiagEuclideanMetric, jitter_rate = 3.0,
    tempering_rate = 3.0, max_depth = 10, Δ_max = 1000,
    n_leapfrog = 10, δ = 0.65, λ = 0.3, progress = false,
    verbose = false)

    # NN parameter prior mean and variance(PriorsNN must be a tuple)
    if isinplace(prob)
        throw(error("The BPINN ODE solver only supports out-of-place ODE definitions, i.e. du=f(u,p,t)."))
    end

    strategy = strategy == GridTraining ? strategy(physdt) : strategy

    if dataset != [nothing] &&
       (length(dataset) < 2 || !(typeof(dataset) <: Vector{<:Vector{<:AbstractFloat}}))
        throw(error("Invalid dataset. dataset would be timeseries (x̂,t) where type: Vector{Vector{AbstractFloat}"))
    end

    if dataset != [nothing] && param == []
        println("Dataset is only needed for Parameter Estimation + Forward Problem, not in only Forward Problem case.")
    elseif dataset == [nothing] && param != []
        throw(error("Dataset Required for Parameter Estimation."))
    end

    if chain isa Lux.AbstractExplicitLayer || chain isa Flux.Chain
        # Flux-vector, Lux-Named Tuple
        initial_nnθ, recon, st = generate_Tar(chain, init_params)
    else
        error("Only Lux.AbstractExplicitLayer and Flux.Chain neural networks are supported")
    end

    if nchains > Threads.nthreads()
        throw(error("number of chains is greater than available threads"))
    elseif nchains < 1
        throw(error("number of chains must be greater than 1"))
    end

    # eltype(physdt) cause needs Float64 for find_good_stepsize
    if chain isa Lux.AbstractExplicitLayer
        # Lux chain(using component array later as vector_to_parameter need namedtuple)
        initial_θ = collect(eltype(physdt),
            vcat(ComponentArrays.ComponentArray(initial_nnθ)))
    else
        initial_θ = collect(eltype(physdt), initial_nnθ)
    end

    # adding ode parameter estimation
    nparameters = length(initial_θ)
    ninv = length(param)
    priors = [
        MvNormal(priorsNNw[1] * ones(nparameters),
            LinearAlgebra.Diagonal(map(abs2, priorsNNw[2] .* ones(nparameters)))),
    ]

    # append Ode params to all paramvector
    if ninv > 0
        # shift ode params(initialise ode params by prior means)
        initial_θ = vcat(initial_θ, [Distributions.params(param[i])[1] for i in 1:ninv])
        priors = vcat(priors, param)
        nparameters += ninv
    end

    t0 = prob.tspan[1]
    # dimensions would be total no of params,initial_nnθ for Lux namedTuples
    ℓπ = LogTargetDensity(nparameters, prob, recon, st, strategy, dataset, priors,
        phystd, l2std, autodiff, physdt, ninv, initial_nnθ)

    try
        ℓπ(t0, initial_θ[1:(nparameters - ninv)])
    catch err
        if isa(err, DimensionMismatch)
            throw(DimensionMismatch("Dimensions of the initial u0 and chain should match"))
        else
            throw(err)
        end
    end

    # Define Hamiltonian system (nparameters ~ dimensionality of the sampling space)
    metric = Metric(nparameters)
    hamiltonian = Hamiltonian(metric, ℓπ, ForwardDiff)

    println("physics Logpdf is : ", physloglikelihood(ℓπ, initial_θ))
    println("prior Logpdf is : ", priorweights(ℓπ, initial_θ))
    println("L2lossData Logpdf is : ", L2LossData(ℓπ, initial_θ))
    println("L2loss2 Logpdf is : ", L2loss2(ℓπ, initial_θ))

    # parallel sampling option
    if nchains != 1
        # Cache to store the chains
        chains = Vector{Any}(undef, nchains)
        statsc = Vector{Any}(undef, nchains)
        samplesc = Vector{Any}(undef, nchains)

        Threads.@threads for i in 1:nchains
            # each chain has different initial NNparameter values(better posterior exploration)
            initial_θ = vcat(randn(nparameters - ninv),
                initial_θ[(nparameters - ninv + 1):end])
            initial_ϵ = find_good_stepsize(hamiltonian, initial_θ)
            integrator = integratorchoice(Integrator, initial_ϵ, jitter_rate,
                tempering_rate)
            adaptor = adaptorchoice(Adaptor, MassMatrixAdaptor(metric),
                StepSizeAdaptor(targetacceptancerate, integrator))
            Kernel = AdvancedHMC.make_kernel(kernelchoice(Kernel, max_depth, Δ_max,
                    n_leapfrog, δ, λ), integrator)
            samples, stats = sample(hamiltonian, Kernel, initial_θ, draw_samples, adaptor;
                progress = progress, verbose = verbose)

            samplesc[i] = samples
            statsc[i] = stats
            mcmc_chain = Chains(hcat(samples...)')
            chains[i] = mcmc_chain
        end

        return chains, samplesc, statsc
    else
        initial_ϵ = find_good_stepsize(hamiltonian, initial_θ)
        integrator = integratorchoice(Integrator, initial_ϵ, jitter_rate, tempering_rate)
        adaptor = adaptorchoice(Adaptor, MassMatrixAdaptor(metric),
            StepSizeAdaptor(targetacceptancerate, integrator))
        Kernel = AdvancedHMC.make_kernel(kernelchoice(Kernel, max_depth, Δ_max, n_leapfrog,
                δ, λ), integrator)
        samples, stats = sample(hamiltonian, Kernel, initial_θ, draw_samples,
            adaptor; progress = progress, verbose = verbose)

        # return a chain(basic chain),samples and stats
        matrix_samples = hcat(samples...)
        mcmc_chain = MCMCChains.Chains(matrix_samples')
        return mcmc_chain, samples, stats
    end
end