Core = use "static-arena-contract-core".
J = use "std/jsondoc".
main : unsafe Unit -> Unit .
>! case args Unit of [root,path] -> print (J.render (Core.verify root path)) | _ -> error "expected ROOT CONTRACT".
