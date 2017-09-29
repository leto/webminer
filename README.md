# Getting started:
1. Install web assembly on server: http://webassembly.org/getting-started/developers-guide/
1. checkout this repo on server
1. cd js-emscripten/ && make
1. Install js-emscripten/miner.html and hushminer.js and hushminer.wasm on web server.
1. Install js-backend/ on server as /ws

# CPU Javascript miner for http://miner.myhush.org

Reimplementation of xenoncat/Tromp algorithm, just to understand
it better by myself.   Performs around the same as Tromp's equi1.
It's single-threaded on purpose, and uses 256 MB of memory now.
The aim was the pure C miner with no dependencies, that works of either
little-endian or big-endian platform (ultrasparc speed is so pathetic).

c/ is portable C sources to produce binary for your platform.

js-emscripten/ is a port to emscipten for mining in WebAssembly-compatible
browser

js-backend/ is a server-side support for browser mining, allows many
sessions (tested up to 30K sessions, many thanks to https://github.com/kosjak1)

pool-emu/ may be handy for debugging your miners.

Code used:
- BLAKE2b reference implementation from RFC 7693
- BLAKE2b optimized for SSE4.1/SSE2, taken from equihash by John Tromp
    https://github.com/tromp/equihash
- SHA-256 taken from cgminer by Con Kolivas
    https://github.com/ckolivas/cgminer/
- JSON parser by Serge A. Zaitsev
    https://github.com/zserge/jsmn

How to run binary:
   ./hushminer -l us.madmining.club -u {workername} -d 3
