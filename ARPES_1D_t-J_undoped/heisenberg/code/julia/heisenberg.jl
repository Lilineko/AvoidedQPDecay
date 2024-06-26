module Heisenberg

using OrderedCollections
using SparseArrays
using KrylovKit
using JSON

"""
`struct System` immutable structure for system input parameters:
# Fields
*   `size::Int64`: number of lattice sites
*   `momentum::Int64`: index indicating which momentum sector should be calculated. Index `momentum` corresponds to momentum `k = 2π * momentum / size`.
*   `magnetization::Int64`: index in range `0:floor(size/2)` indicating which magnetization sector should be calculated. Magnetization is taken without sign.
*   `coupling::Float64`: value of the coupling constant J. For ferromagnet `coupling < 0`, while for antiferromagnet `coupling > 0`.
*   `interaction::FLoat64`: parameter for scaling magnon-magnon interactions. For pure Heisenberg model `interaction = 1.0`.
"""
struct System
    size::Int64
    momentum::Int64
    magnetization::Int64
    coupling::Float64
    anisotropy::Float64
    interaction::Float64
end

"`Basis === OrderedDict{Int64, Int64}`"
Basis = OrderedDict{Int64, Int64}

"""
`mutable struct LinearCombination`: structure for storing result of operators action on states belonging to `basis::Basis`
# Fields
*   `state::Int64`: magnon configuration in binary representation written as decimal number
*   `coefficient::Vector{Complex{Float64}}`: coeffcient multiplying state in the linear combination
"""
mutable struct LinearCombination
    state::Vector{Int64}
    coefficient::Vector{Complex{Float64}}
end

"`Model === SparseMatrixCSC{Complex{Float64},Int64}`"
Model = SparseMatrixCSC{Complex{Float64},Int64}

"""
    run()

Run Heisenberg model diagonalization procedure.
"""
function run(input::Union{Missing, OrderedDict} = missing)
    system::System = if input === missing
        readInput()
    else
        System(
            input["system size"],
            input["momentum sector"],
            input["magnetization sector"],
            input["coupling constant"],
            input["anisotropy"],
            input["magnon interaction"]
        )
    end
    basis::Basis = makeBasis(system)
    model::Model = makeModel(basis, system)
    factorization = factorize(model)
    return system, basis, factorization
end

"Read `input.json` file and return `System` structure with input data. It requires `input.json` file to be located in the current working directory."
function readInput()::System
    path = "./heisenberg/code/julia/"
    input = JSON.parsefile(path * "input.json", use_mmap = false) # use_mmap = false is a workaroud to ensure one can change JSON file without restarting Julia
    return System(
        input["system size"],
        input["momentum sector"],
        input["magnetization sector"],
        input["coupling constant"],
        input["anisotropy"],
        input["magnon interaction"]
    )
end

"""
    makeBasis(system::System) -> Basis

Return `Basis === Dict{Int64, Int64}` dictionary representing basis of given magnetization and momentum sector specified by `system.magnetization` and `system.momentum` respectively. Each index in `Basis` corresponds to state value, and each value in `Basis` corresponds to position in the basis.
"""
function makeBasis(system::System)::Basis
    if isodd(system.size)
        error("Requested 'system.size' is odd! Only even sizes are supported.")
    end
    if (system.magnetization < 0) || (2 * system.magnetization > system.size)
        error("Wrong magnetization sector in the input file! Possible subspaces are denoted by integers from 0 to N/2.")
    end

    ### get maximum number of spins pointing in the same direction (up or down)
    nSpinsUp::Int64 = div(system.size, 2) - system.magnetization
    ### note: in the code `spin up === 1`, `spin down === 0`

    ### calculate magnetic subspace size: initialize with binomial
    subspaceSize::Int64 = binomial(system.size, nSpinsUp)

    ### get first state (i.e. with lowest index in binary basis)
    ### note: `1 << n == 2^n`, but former is faster
    state::Int64 = nSpinsUp == 0 ? 0 : sum(n -> 1 << n, 0 : (nSpinsUp - 1))

    ### set sublattice rotation mask
    mask = sum(1 << k for k in 0:2:(system.size - 1))

    ### initialize the basis
    basis::Basis = Basis()

    index = 0
    ### iterate over states within given magnetization subspace
    for _ in 1:subspaceSize
        ### perform sublattice rotation
        magnonState = sublatticeRotation(state, mask)
        ### now 1 represents magnon, 0 stands for empty site

        ### check if state belongs to requested momentum subspace
        if hasMomentum(magnonState, system)
            ### pick representative state
            repState = getRepresentative(magnonState, system)

            ### check if repState is already included
            if get(basis, repState, nothing) === nothing
                ### if not then add repState to basis
                push!(basis, repState => (index += 1))
            end
        end

        ### get next state (in spin language)
        state = getNextState(state, system)
    end

    ### Since our model for β ≂̸ 1 does not commute with
    ### translation operator, we are going to use different
    ### operator to further simplify the diagonalization.
    ### This requires joining the subspaces with
    ### the same absolute value of magnetization.
    ### Due to simple facts of how magnon and spin representations
    ### are connected to get full basis it is enough
    ### to iterate over half of spin states

    return basis
end

"""
    sublatticeRotation(state::Int64, mask::Int64) -> Int64

Reverse bits according to mask.
"""
function sublatticeRotation(state::Int64, mask::Int64)::Int64
    return xor(state, mask)
end

"""
    hasMomentum(state::Int64, system::System) -> Bool

Return `True` if `state` belongs to `system.momentum` subspace or returns `False` otherwise.
"""
function hasMomentum(state::Int64, system::System)::Bool
    ### system.size must divide system.momentum times periodicity
    return rem(system.momentum * getPeriodicity(state, system), system.size) == 0
end

"""
    getPeriodicity(state::Int64, system::System) -> Int64

Return periodicity of the `state` within given `system` parameters.
"""
function getPeriodicity(state::Int64, system::System)::Int64
    ### initialize some constants for faster evaluation
    l::Int = system.size
    highestBit::Int = 1 << (l - 1)
    highestValue::Int = (1 << l) - 1

    ### initialize state translation
    stateTranslation = state

    ### periodicity is smallest positive number of translations
    ### that transform state onto itself
    periodicity::Int64 = 1
    while state != (stateTranslation = bitmov(stateTranslation, l, false, hb = highestBit, hv = highestValue))
        periodicity += 1
    end

    return periodicity
end

"""
    getRepresentative(state::Int64, system::System) -> Int64

Return representative state `repState::Int64` of `state::Int64` within given `system::System` parameters.
`repState::Int64` is a cyclic translation of `state::Int64` that has smallest possible value.
"""
function getRepresentative(state::Int64, system::System)::Int64
    ### initialize some constants for faster evaluation
    l::Int = system.size
    highestBit::Int = 1 << (l - 1)
    highestValue::Int = (1 << l) - 1

    ### initialize result as state
    result = state

    ### loop over translations of state
    newState = state
    while state != (newState = bitmov(newState, l, false, hb = highestBit, hv = highestValue))
        ### replace returned state if translation has lower value
        if result > newState
            result = newState
        end
    end

    ### returned value is so called representative state
    ### i.e. it is the same state as initial one (with respect
    ### to cyclic translation) but it has smallest possible
    ### value within the familly of translations of initial state
    return result
end

"""
    getStateInfo(state::Int64, system::System) -> (Int64, Int64)

Combine `hasMomentum` and `getRepresentative` and `getPeriodicity` in one more efficient function. In addition returns distance between `state` and its represantative state calculated in number of translations needed to transform one onto another.
"""
function getStateInfo(state::Int64, system::System)::Tuple{Bool, Int64, Int64, Int64}
    ### initialize some constants for faster evaluation
    l::Int = system.size
    highestBit::Int = 1 << (l - 1)
    highestValue::Int = (1 << l) - 1

    ### initialize representative as state
    representative = state

    ### loop over translations of state
    newState = state
    distance::Int64 = 0
    periodicity::Int64 = 1
    while state != (newState = bitmov(newState, l, false, hb = highestBit, hv = highestValue))
        if representative > newState
            representative = newState
            distance = periodicity
        end
        periodicity += 1
    end

    hasMomentum = rem(system.momentum * periodicity, system.size) == 0
    return (hasMomentum, representative, periodicity, distance)
end

"""
    getNextState(system::System, state::Int64) -> Int64

Return `newState::Int64` next to `state::Int64` within given magnetization sector specified by `system.magnetization`.
Two states, `state` and `newState`, are next to each other withing given magentization sector if and only if there is no state that has value between `state` and `newState`.
"""
function getNextState(state::Int64, system::System)::Int64
    count = 0
    ### loop over <i,j> site pairs (bonds)
    for i in 0:(system.size - 2)
        j = i + 1

        ### get numeric value at i and j bit positions
        iValue, jValue = 1 << i, 1 << j

        ### check if there is bit 1 at site i
        if state & iValue > 0
            ### check if there is bit 1 at site j
            if state & jValue > 0
                ### clear bit at site i
                state &= ~iValue

                ### raise counter of cleared bits
                count += 1
            else
                ### swap bits at i and j
                state = xor(state, iValue + jValue)

                ### add cleared bits to lowest positions
                state += count == 0 ? 0 : sum(n -> 1 << n, 0:(count-1))

                ### return new state
                return state
            end
        end
    end
    ### if loop ends without returning new state we return -1
    ### as there is no next state in the requestes subspace
    return -1
end

"""
    bitmov(s::Int, l::Int, f::Bool = false; hb::Int = 1 << (l - 1), hv::Int = (1 << l) - 1) -> Int

Cyclic bit shift for calculationg bit translations with periodic boundary conditions.

# Arguments
*   `s::Int` - value which binary representation will be shifted
*   `l::Int` - size of the cycle (total number of bits in the cycle)
*   `f::Bool` - `true ->` move forward (~mult by `2`); `false ->` backward (~div by `2`); ~mult and ~div mean multiplication and division with preservance of periodic boundary conditions within cycle size `l`
*   `hb::Int` [optional] - highest bit (for speed up put the value of 2^(l-1))
*   `hv::Int` [optional] - highest value (for speed put (2^l)-1)
"""
@inline bitmov(s::Int, l::Int, f::Bool = false; hb::Int = 1 << (l - 1), hv::Int = (1 << l) - 1) = f ? 2s - div(s, hb) * hv : div(s, 2) + rem(s, 2) * hb

"""
    act(operator::Function, state::Int64, basis::Basis, system::System) -> LinearCombination

Apply `operator` to `state` belonging to `basis` and returns `LinearCombination  === Dict{Int64, Complex{Float64}}` representing states with their coefficients.
"""
function act(operator::Function, state::Int64, basis::Basis, system::System)::LinearCombination
    return operator(state, basis, system)
end

"""
    hamiltonian(state::Int64, basis::Basis, system::System) -> LinearCombination

Apply Hamiltonian to `state` written in hole-magnon momentum `basis` obtained for input `system` parameters. Returns `LinearCombination` structure representing resulting states with their coefficients.
"""
function hamiltonian(state::Int64, basis::Basis, system::System)::LinearCombination
    ### initialize result as empty linear combination
    result = LinearCombination(fill(state, system.size + 1), zeros(Complex{Float64}, system.size + 1))

    ### check if initial state belongs to basis
    if haskey(basis, state)
        ### initialize ik for faster exponent calculations
        ik::Complex{Float64} = 2.0 * pi * im * system.momentum / system.size

        ### calculate state periodicity
        periodicity = getPeriodicity(state, system)

        ### loop over lattice sites
        for i in 1:system.size
            j = mod1(i + 1, system.size)

            ### get bit value at i and j bit positions
            iValue, jValue = (1 << (i - 1)), (1 << (j - 1))

            ## work out off-diagonal coeffcients
            iBit, jBit = div(state & iValue, iValue), div(state & jValue, jValue)
            if iBit == jBit
                ### if two neighbouring spins are the same then flip those spins
                newState = xor(state, iValue + jValue)
                ### remember we applied the sublattice rotation creating the basis
                ### this is why we flip spins when they are the same
                ### it corresponds to creating pair of magnons in two nearest
                ### empty sites or annihilating pair of neighboring magnons

                ### get info about state after spin flip
                hasMomentum, repState, repPeriodicity, distance = getStateInfo(newState, system)

                ### check if it belongs to correct momentum subspace
                ### if it does not, then it will cancel out with other terms
                ### after summing over all the sites
                if hasMomentum
                    ### calculate matrix coefficient
                    coefficient = 0.5 * exp(ik * distance) * sqrt(periodicity / repPeriodicity)

                    ### create a new entry in linear combination
                    ### and set its corresponding coeffcient
                    result.state[i + 1] = repState
                    result.coefficient[i + 1] = coefficient
                end
            end

            ## work out diagonal coefficient (Sz Sz terms; comment out for XY model)
            ## comment: after rotation bits represent magnons (0 -> no magnon, 1 -> magnon present)
            iBit, jBit = div(state & iValue, iValue), div(state & jValue, jValue)
            result.coefficient[1] -= (0.25 - 0.5 * (iBit + jBit) + system.interaction * iBit * jBit) * system.anisotropy
        end

        ### multiply the result by coupling constant
        result.coefficient .*= system.coupling
    end

    ### return resulting linear combination
    return result
end

"""
    makeModel(basis::Basis, system::System) -> Model

Calculate sparse matrix of the `Model` Hamiltonian. Returns `Model === Array{Complex{Float64},2}`.
"""
function makeModel(basis::Basis, system::System)::Model
    subspaceSize = length(basis)
    linearCombinationLength = system.size + 1
    I = Vector{Int64}(undef, linearCombinationLength * subspaceSize)
    J = Vector{Int64}(undef, linearCombinationLength * subspaceSize)
    V = Vector{Complex{Float64}}(undef, linearCombinationLength * subspaceSize)
    for (state, index) in basis
        linearCombination::LinearCombination = act(hamiltonian, state, basis, system)
        for it in 1:linearCombinationLength
            I[(index - 1) * linearCombinationLength + it] = index
            J[(index - 1) * linearCombinationLength + it] = basis[linearCombination.state[it]]
            V[(index - 1) * linearCombinationLength + it] = linearCombination.coefficient[it]
        end
    end
    return dropzeros!(sparse(I, J, V, subspaceSize, subspaceSize, +))
end

"""
    factorize(model::Model, [howmany = 1, which = :SR])

Compute eigenvalues (by default with smallest real part) and their corresponding eigenvectors.
"""
function factorize(model::Model; howmany = 1, which = :SR)
    if length(model) != 0
        return eigsolve(model, howmany, which, ishermitian = true)
    else
        return (missing, missing, missing)
    end
end

# """
#     saveResult(factorization)
#
# Take output of the `factorize(model::Model)` and write file with convergance info, norm of ritz resudual for smallest eigenvalue, smallest eigenvalue and its corresponding eigenvector.
# """
# function saveResult(factorization)
#     vals, vecs, info = factorization
#     file = open("result.txt", "w")
#     write(file, string("Converged:", "\n", info.converged, "\n\n"))
#     write(file, string("Norm of Residual:", "\n", info.normres[1], "\n\n"))
#     write(file, string("Eigenvalue:", "\n", vals[1], "\n\n"))
#     write(file, string("Eigenvector:", "\n"))
#     for coeff in vecs[1]
#         write(file, string(coeff, "\n"))
#     end
#     close(file)
# end
#
end
