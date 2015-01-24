## expand product of two sums
function mulsums(a::Mxpr{:Plus},b::Mxpr{:Plus})
    terms = newargs()
    for ax in a.args
        for bx in b.args
            push!(terms,ax * bx)
        end
    end
    # efficiency, we need to limit this to two levels deep.
    # i.e., we need level specifications
    deepcanonexpr!(mxpr(:Plus,terms...))
end

mulsums(a::Mxpr{:Plus},b::Mxpr{:Plus},c::Mxpr{:Plus}) = mulsums(mulsums(a,b),c)
mulsums(a::Mxpr{:Plus},b::Mxpr{:Plus},c::Mxpr{:Plus}, xs::Mxpr{:Plus}...) = mulsums(mulsums(mulsums(a,b),c),xs...)


function apprules(mx::Mxpr{:Apply})
    doapply(mx,mx[1],mx[2])
end

doapply(mx::Mxpr,h::SJSym,mxa::Mxpr) = mxpr(h,(mxa.args)...)
doapply(mx,x,y) = mx