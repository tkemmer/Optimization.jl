module OptimizationGCMAES

using Reexport
@reexport using Optimization
using GCMAES, Optimization.SciMLBase

export GCMAESOpt

struct GCMAESOpt end

SciMLBase.requiresbounds(::GCMAESOpt) = true
SciMLBase.allowsbounds(::GCMAESOpt) = true
SciMLBase.allowscallback(::GCMAESOpt) = false

struct GCMAESOptimizationCache{F <: OptimizationFunction, RC, LB, UB, S, O, P, S0} <:
       SciMLBase.AbstractOptimizationCache
    f::F
    reinit_cache::RC
    lb::LB
    ub::UB
    sense::S
    opt::O
    progress::P
    sigma0::S0
    solver_args::NamedTuple
end

function Base.getproperty(cache::GCMAESOptimizationCache, x::Symbol)
    if x in fieldnames(Optimization.ReInitCache)
        return getfield(cache.reinit_cache, x)
    end
    return getfield(cache, x)
end

function GCMAESOptimizationCache(prob::OptimizationProblem, opt; progress, sigma0,
                                 kwargs...)
    reinit_cache = Optimization.ReInitCache(prob.u0, prob.p) # everything that can be changed via `reinit`
    f = Optimization.instantiate_function(prob.f, reinit_cache, prob.f.adtype)
    return GCMAESOptimizationCache(f, reinit_cache, prob.lb, prob.ub, prob.sense, opt,
                                   progress, sigma0,
                                   NamedTuple(kwargs))
end

SciMLBase.supports_opt_cache_interface(opt::GCMAESOpt) = true
SciMLBase.has_reinit(cache::GCMAESOptimizationCache) = true
function SciMLBase.reinit!(cache::GCMAESOptimizationCache; p = missing, u0 = missing)
    if p === missing && u0 === missing
        p, u0 = cache.p, cache.u0
    else # at least one of them has a value
        if p === missing
            p = cache.p
        end
        if u0 === missing
            u0 = cache.u0
        end
        if (eltype(p) <: Pair && !isempty(p)) || (eltype(u0) <: Pair && !isempty(u0)) # one is a non-empty symbolic map
            hasproperty(cache.f, :sys) && hasfield(typeof(cache.f.sys), :ps) ||
                throw(ArgumentError("This cache does not support symbolic maps with `remake`, i.e. it does not have a symbolic origin." *
                                    " Please use `remake` with the `p` keyword argument as a vector of values, paying attention to parameter order."))
            hasproperty(cache.f, :sys) && hasfield(typeof(cache.f.sys), :states) ||
                throw(ArgumentError("This cache does not support symbolic maps with `remake`, i.e. it does not have a symbolic origin." *
                                    " Please use `remake` with the `u0` keyword argument as a vector of values, paying attention to state order."))
            p, u0 = SciMLBase.process_p_u0_symbolic(cache, p, u0)
        end
    end

    cache.reinit_cache.p = p
    cache.reinit_cache.u0 = u0

    return cache
end

function __map_optimizer_args(cache::GCMAESOptimizationCache, opt::GCMAESOpt;
                              callback = nothing,
                              maxiters::Union{Number, Nothing} = nothing,
                              maxtime::Union{Number, Nothing} = nothing,
                              abstol::Union{Number, Nothing} = nothing,
                              reltol::Union{Number, Nothing} = nothing)

    # add optimiser options from kwargs
    mapped_args = (;)

    if !(isnothing(maxiters))
        mapped_args = (; mapped_args..., maxiter = maxiters)
    end

    if !(isnothing(maxtime))
        @warn "common maxtime is currently not used by $(opt)"
    end

    if !isnothing(abstol)
        @warn "common abstol is currently not used by $(opt)"
    end

    if !isnothing(reltol)
        @warn "common reltol is currently not used by $(opt)"
    end

    return mapped_args
end

function SciMLBase.__init(prob::OptimizationProblem, opt::GCMAESOpt;
                          maxiters::Union{Number, Nothing} = nothing,
                          maxtime::Union{Number, Nothing} = nothing,
                          abstol::Union{Number, Nothing} = nothing,
                          reltol::Union{Number, Nothing} = nothing,
                          progress = false,
                          σ0 = 0.2,
                          kwargs...)
    maxiters = Optimization._check_and_convert_maxiters(maxiters)
    maxtime = Optimization._check_and_convert_maxtime(maxtime)
    return GCMAESOptimizationCache(prob, opt; maxiters, maxtime, abstol, reltol, progress,
                                   sigma0 = σ0, kwargs...)
end

function SciMLBase.__solve(cache::GCMAESOptimizationCache)
    local x
    local G = similar(cache.u0)

    _loss = function (θ)
        x = cache.f.f(θ, cache.p)
        return x[1]
    end

    if !isnothing(cache.f.grad)
        g = function (θ)
            cache.f.grad(G, θ)
            return G
        end
    end

    opt_args = __map_optimizer_args(cache, cache.opt, maxiters = cache.solver_args.maxiters,
                                    maxtime = cache.solver_args.maxtime,
                                    abstol = cache.solver_args.abstol,
                                    reltol = cache.solver_args.reltol; cache.solver_args...)

    t0 = time()
    if cache.sense === Optimization.MaxSense
        opt_xmin, opt_fmin, opt_ret = GCMAES.maximize(isnothing(cache.f.grad) ? _loss :
                                                      (_loss, g), cache.u0,
                                                      cache.sigma0, cache.lb,
                                                      cache.ub; opt_args...)
    else
        opt_xmin, opt_fmin, opt_ret = GCMAES.minimize(isnothing(cache.f.grad) ? _loss :
                                                      (_loss, g), cache.u0,
                                                      cache.sigma0, cache.lb,
                                                      cache.ub; opt_args...)
    end
    t1 = time()

    SciMLBase.build_solution(cache, cache.opt,
                             opt_xmin, opt_fmin; retcode = Symbol(Bool(opt_ret)),
                             solve_time = t1 - t0)
end

end
