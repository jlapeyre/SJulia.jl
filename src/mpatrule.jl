## Pattern matching and rules
# This is not called from meval, rather via code in pattern.jl

typealias UExpr  Mxpr  # annotation for expressions in Unions
# pieces of expressions that we operate on are Symbols and expressions
typealias ExSym Union(UExpr,Symbol,SJSym)
# TODO: need to split this up and separate them by dispatch, or just make this Any
typealias CondT Union(ExSym,DataType,Function)

# Pattern variable. name is the name, ending in underscore cond is a
# condition that must be satisfied to match But, cond may be :All,
# which matches anything.  The most imporant feature is that the Pvar
# matches based on its context in an AST.
type Pvar
    name::Symbol  # name
    head::Symbol  # head to match
    ptest::Symbol   # head of "function" to call (meval) for bool test
end
typealias ExSymPvar Union(ExSym,Pvar)

# we could allow non-underscored names
function Pvar(name::Symbol)
    Pvar(name,:All,:All)
end

==(a::Pvar, b::Pvar) = (a.name == b.name && a.ptest == b.ptest)

# ast is the pattern including Pvars for capture.
# cond is condition to apply to any Pvars in the pattern
#
# Hack to get around hack. We are polluting Julia namespace
# with SJSym's just to get repl completion.
# So 'Pattern' is already used. So we use PatternT.
# But, we will fix the repl and rewrite code.
type PatternT
    ast::Any
    cond::CondT
end

PatternT(ast::ExSymPvar) = PatternT(ast,:All)
pattern(ast::ExSym) = pattern(ast,:All)

function Base.show(io::IO, pv::Pvar)
    show(io,pv.name)
end

function Base.show(io::IO, p::PatternT)
    show(io,p.ast)
end

pattern(x,cond::Symbol) = PatternT(x,cond)
pattern(x) = pattern(x,:All)

# replacement rule
# lhs is a pattern for matching.
# rhs is a template pattern for replacing.
type PRule
    lhs::PatternT
    rhs::PatternT
end

function Base.show(io::IO, p::PRule)
    print(io,"rule: ")
    show(io,p.lhs)
    print(io, " => ")
    show(io,p.rhs)
end

## most of this stuff is old. works in Julia, not SJulia
PRule(lhs::ExSym, rhs::ExSym) = PRule(pattern(lhs),pattern(rhs))
==(a::PRule, b::PRule) =  (a.lhs == b.lhs && a.rhs == b.rhs)
==(a::PatternT, b::PatternT) = (a.ast == b.ast)
prule(x,y) = PRule(x,y)
# syntax for creating a rule. collides with Dict syntax sometimes.
=>(lhs::ExSym,rhs::ExSym) = prule(pattern(lhs),pattern(rhs))
=>(lhs::ExSym,rhs::Symbol) = prule(pattern(lhs),pattern(rhs))
=>(lhs::ExSym,rhs::Number) = prule(pattern(lhs),pattern(rhs))
prule(lhs::Mxpr, rhs::Mxpr) = prule(pattern(lhs),pattern(rhs))
prule(x::Mxpr, y::Number) = prule(pattern(x),pattern(y))

getpvarptest(pvar::Pvar) = pvar.ptest
getpvarhead(pvar::Pvar) = pvar.head

# Perform match and capture.
function cmppat(ex,pat::PatternT)
    capt = capturealloc() # Array(Any,0)  # allocate capture array
    success_flag = _cmppat(ex,pat.ast,capt) # do the matching
    return (success_flag,capt)  # report whether matched, and return captures    
end
cmppat(ex,pat::ExSym) = cmppat(ex,pattern(pat))

capturealloc() = Dict{Symbol,Any}()

# capture expression ex in pvar, or return false if the new value conflicts with old.
function capturepvar(capt,pvar,ex)
    name = pvar.name
    haskey(capt,name) && capt[name] != ex  && return false
    capt[name] = ex
    return true
end

# store captured expression in Dict. Here only the capture var name
storecapt(pat,cap,cd) = cd[pat] = cap
# retrieve captured expression by caption var name
retrievecapt(sym,cd) = cd[sym]
retrievecapt(sym::SJSym,cd) = cd[symname(sym)]
havecapt(sym,cd) = haskey(cd,sym)
havecapt(sym::SJSym,cd) = haskey(cd,symname(sym))

# check if restriction on Head and pattern test
# are satisfied.
# TODO: reorganize. maybe make type of Pvar.head Any
# so it can be a Symbol (only for finding SJSym),
# or a DataType. This is determined when the Pvar is
# created (of course later, this should be done once and stored with the downvalue)
# Then, much of the logic below can be eliminated
function matchpat(cvar,ex)
    @mdebug(1, "matchpat entering ex = ", ex)
    local headmatch  # does the head match ?
    local ptestmatch  # is the pattern test satisfied ?
    isdatatype = false  # does head-to-match evaluate to a DataType ?
    hh = getpvarhead(cvar)  # head to match
    if is_type(hh,Symbol)
        if isdefined(hh) # Julia symbol represents data type ?
            hhe = eval(hh)
            if is_type(hhe,DataType)
                isdatatype = true
                if is_type_less(ex,hhe)
                    headmatch = true
                else
                    headmatch = false
                end
            end
        end
        if ! isdatatype
            if hh == :All || is_Mxpr(ex,hh)
                headmatch = true
            else
                headmatch = false
            end
        end
    else
        error("matchpat: Head to match is not a symbol")
    end
    headmatch || return false
    cc = getpvarptest(cvar)
    is_type(cc,Symbol) || error("matchpat: Pattern test to match is not a symbol")
    if cc != :None
        testmx = mxpr(cc,ex)
        ptestmatch = (infseval(testmx) == true)
    else
        ptestmatch = true
    end
    return ptestmatch
end

# For non-orderless, non-flat matching only
# Descend expression tree. If there is no pattern var in
# a subexpression of pattern `pat', then the subexpressions in
# mx and pat must match exactly.
# If pat is a capture var, then it matches the subexpression ex,
# if the condition as checked by matchpat is satisfied.

# capturevar -> false means contradicts previous capture
_cmppat(mx,pat::Pvar,captures)  = matchpat(pat,mx) ? capturepvar(captures,pat,mx) : false
function _cmppat(mx::Mxpr,pat::Mxpr,captures)
    (mhead(pat) == mhead(mx) && length(pat) == length(mx)) || return false
    @inbounds for i in 1:length(mx)      # match and capture subexpressions
         _cmppat(mx[i],pat[i],captures) == false && return false
    end
    return true
end

_cmppat(mx,pat,captures) = mx == pat  # 'leaf' on the tree. Must match exactly.
# Allow different kinds of integers and floats to match
_cmppat{T<:Integer,V<:Integer}(mx::T,pat::V,captures) = mx == pat
_cmppat{T<:FloatingPoint,V<:FloatingPoint}(mx::T,pat::V,captures) = mx == pat
# In general, Numbers should be === to match. Ie. floats and ints are not the same
_cmppat{T<:Number,V<:Number}(mx::T,pat::V,captures) = mx === pat


# match and capture on ex with pattern pat1.
# Replace pattern vars in pat2 with expressions captured from ex.
# Copying Dict is inefficient!
function patrule(ex,pat1::PatternT,pat2::PatternT)
    @mdebug(1, "enter patrule with ", ex)
    (res,capt) = cmppat(ex,pat1)
    res == false && return false # match failed
    npat = deepcopy(pat2) # deep copy and x_ -> pat(x)    
    cd = Dict{Any,Any}()   
    for (p,c) in capt  # type inferred? move to aux function ?
        storecapt(p,c,cd) # throw away condition information
    end
    nnpat = patsubst!(npat.ast,cd) # do replacement
    nnpat
end
patrule(ex,pat1::ExSym,pat2::ExSym) = patrule(ex,pattern(pat1),pattern(pat2))

# Same as patrule, except if match fails, return original expression
function tpatrule(ex,pat1,pat2)
    res = patrule(ex,pat1,pat2)
    res === false ? ex : res
end

# apply replacement rule r to expression ex
replace(ex::ExSym, r::PRule) = tpatrule(ex,r.lhs,r.rhs)

replacefail(ex::ExSym, r::PRule) = patrule(ex,r.lhs,r.rhs)

# Do depth-first replacement applying the same rule to head and each subexpression
function replaceall(ex,pat1::PatternT,pat2::PatternT)
    if is_Mxpr(ex)
        ex = mxpr(replaceall(mhead(ex),pat1,pat2),
                    map((x)->replaceall(x,pat1,pat2),margs(ex))...)
    end
    # we have applied replacement at all lower levels. Now do current level.
    res = patrule(ex,pat1,pat2)
    res === false && return ex # match failed; return unaltered expression
    res
end

replaceall(ex, r::PRule) = replaceall(ex,r.lhs,r.rhs)

# TODO, check replaceall below and replacerepeated to see that they
# replace heads as does replaceall above.

# Apply an array of rules. each subexpression is tested.
# Continue after first match for each expression.
function replaceall(ex,rules::Array{PRule,1})
    if is_Mxpr(ex)
        ex = mxpr(mhead(ex),
                    map((x)->replaceall(x,rules),margs(ex))...)
    end
    for r in rules
        res = patrule(ex,r.lhs,r.rhs)
        res !== false && return res
    end
    ex
end

# Do the substitution recursively.
# pat is the template pattern: an expression with 0 or more pattern vars.
# cd is a Dict with pattern var names as keys and expressions as vals.
# Subsitute the pattern vars in pat with the vals from cd.
# Version for new pattern matching format:  x_ => x^2

function patsubst!(pat::Mxpr,cd)
    if ! havecapt(pat,cd)
        pa = margs(pat)
        @inbounds for i in 1:length(pa)
            if havecapt(pa[i],cd)
                pa[i] =  retrievecapt(pa[i],cd)
            elseif is_Mxpr(pa[i])
                pa[i] = patsubst!(pa[i],cd)
            end
        end
    end
    return pat
end

patsubst!(pat::SJSym,cd) = return  havecapt(pat,cd) ? retrievecapt(pat,cd) : pat
patsubst!(pat::Pvar,cd) = retrievecapt(pat,cd)
patsubst!(pat,cd) = pat

## ReplaceRepeated

# This applies the rules to all sub-expressions, and the expression.
# Repeat till we reach a fixed point
replacerepeated(ex, rules::Array{PRule,1}) = _replacerepeated(ex,rules,0)
replacerepeated(ex, therule::PRule) = _replacerepeated(ex,[therule],0)

function _replacerepeated(ex, rules::Array{PRule,1},n)
    n > 10^5 && error("Exceeded max iterations, $n, in replacerepeated")
    ex1 = ex
    if is_Mxpr(ex)
        ex1 = mxpr(mhead(ex), #  margs(ex,1),  # careful, we changed this and it is not well tested
              map((x)->replacerepeated(x,rules),margs(ex)[1:end])...)
    end
    local res
    for r in rules
        res = patrule(ex1,r.lhs,r.rhs)
        if (res !== false)
            ex1 = res
            break
        end
    end
    if ex != ex1
        ex1 = _replacerepeated(ex1,rules,n+1)
    end
    ex1
end

nothing
