module OptimizationBBO

using Reexport
@reexport using Optimization
using BlackBoxOptim, Optimization.SciMLBase

abstract type BBO end

SciMLBase.requiresbounds(::BBO) = true
SciMLBase.allowsbounds(::BBO) = true

for j in string.(BlackBoxOptim.SingleObjectiveMethodNames)
    eval(Meta.parse("Base.@kwdef struct BBO_" * j * " <: BBO method=:" * j * " end"))
    eval(Meta.parse("export BBO_" * j))
end

function decompose_trace(opt::BlackBoxOptim.OptRunController, progress)
    if progress
        maxiters = opt.max_steps
        max_time = opt.max_time
        msg = "loss: " * sprint(show, best_fitness(opt), context = :compact => true)
        if iszero(max_time)
            # we stop at either convergence or max_steps
            n_steps = BlackBoxOptim.num_steps(opt)
            Base.@logmsg(Base.LogLevel(-1), msg, progress=n_steps / maxiters,
                         _id=:OptimizationBBO)
        else
            # we stop at either convergence or max_time
            elapsed = BlackBoxOptim.elapsed_time(opt)
            Base.@logmsg(Base.LogLevel(-1), msg, progress=elapsed / max_time,
                         _id=:OptimizationBBO)
        end
    end
    return BlackBoxOptim.best_candidate(opt)
end

function __map_optimizer_args(prob::SciMLBase.OptimizationProblem, opt::BBO;
                              callback = nothing,
                              maxiters::Union{Number, Nothing} = nothing,
                              maxtime::Union{Number, Nothing} = nothing,
                              abstol::Union{Number, Nothing} = nothing,
                              reltol::Union{Number, Nothing} = nothing,
                              verbose::Bool = false,
                              kwargs...)
    if !isnothing(reltol)
        @warn "common reltol is currently not used by $(opt)"
    end
    mapped_args = (; kwargs...)
    mapped_args = (; mapped_args..., Method = opt.method,
                   SearchRange = [(prob.lb[i], prob.ub[i]) for i in 1:length(prob.lb)])

    if !isnothing(callback)
        mapped_args = (; mapped_args..., CallbackFunction = callback,
                       CallbackInterval = 0.0)
    end

    if !isnothing(maxiters)
        mapped_args = (; mapped_args..., MaxSteps = maxiters)
    end

    if !isnothing(maxtime)
        mapped_args = (; mapped_args..., MaxTime = maxtime)
    end

    if !isnothing(abstol)
        mapped_args = (; mapped_args..., MinDeltaFitnessTolerance = abstol)
    end

    if verbose
        mapped_args = (; mapped_args..., TraceMode = :verbose)
    else
        mapped_args = (; mapped_args..., TraceMode = :silent)
    end

    return mapped_args
end

function SciMLBase.__solve(prob::SciMLBase.OptimizationProblem, opt::BBO,
                           data = nothing;
                           callback = nothing,
                           maxiters::Union{Number, Nothing} = nothing,
                           maxtime::Union{Number, Nothing} = nothing,
                           abstol::Union{Number, Nothing} = nothing,
                           reltol::Union{Number, Nothing} = nothing,
                           verbose::Bool = false,
                           progress = false, kwargs...)
    local x, cur, state

    if !isnothing(data)
        maxiters = length(data)
        cur, state = iterate(data)
    end

    function _cb(trace)
        if isnothing(callback)
            cb_call = false
        else
            cb_call = callback(decompose_trace(trace, progress), x...)
        end

        if !(typeof(cb_call) <: Bool)
            error("The callback should return a boolean `halt` for whether to stop the optimization process.")
        end
        if cb_call == true
            BlackBoxOptim.shutdown_optimizer!(trace) #doesn't work
        end

        if !isnothing(data)
            cur, state = iterate(data, state)
        end
        cb_call
    end

    maxiters = Optimization._check_and_convert_maxiters(maxiters)
    maxtime = Optimization._check_and_convert_maxtime(maxtime)

    _loss = function (θ)
        if isnothing(callback) && isnothing(data)
            return first(prob.f(θ, prob.p))
        elseif isnothing(callback)
            return first(prob.f(θ, prob.p, cur...))
        elseif isnothing(data)
            x = prob.f(θ, prob.p)
            return first(x)
        else
            x = prob.f(θ, prob.p, cur...)
            return first(x)
        end
    end

    opt_args = __map_optimizer_args(prob, opt,
                                    callback = isnothing(callback) && isnothing(data) ?
                                               nothing : _cb,
                                    maxiters = maxiters,
                                    maxtime = maxtime, abstol = abstol, reltol = reltol;
                                    verbose = verbose, kwargs...)

    opt_setup = BlackBoxOptim.bbsetup(_loss; opt_args...)

    t0 = time()

    if isnothing(prob.u0)
        opt_res = BlackBoxOptim.bboptimize(opt_setup)
    else
        opt_res = BlackBoxOptim.bboptimize(opt_setup, prob.u0)
    end

    if progress
        # Set progressbar to 1 to finish it
        Base.@logmsg(Base.LogLevel(-1), "", progress=1, _id=:OptimizationBBO)
    end

    t1 = time()

    opt_ret = Symbol(opt_res.stop_reason)

    SciMLBase.build_solution(SciMLBase.DefaultOptimizationCache(prob.f, prob.p), opt,
                             BlackBoxOptim.best_candidate(opt_res),
                             BlackBoxOptim.best_fitness(opt_res); original = opt_res,
                             retcode = opt_ret, solve_time = t1 - t0)
end

end
