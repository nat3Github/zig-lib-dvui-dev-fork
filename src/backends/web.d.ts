declare namespace DVUI {
    type WasmArg =
        | string
        | WebAssembly.WebAssemblyInstantiatedSource
        | Promise<WebAssembly.WebAssemblyInstantiatedSource>
        | ((imports: WebAssembly.Imports) => Promise<WebAssembly.WebAssemblyInstantiatedSource>)
        ;

    type AllocatorFunction = (len: number) => number;
}