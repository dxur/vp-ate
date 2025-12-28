= Memory management
This file basically tries to model the memory management
and resource managment in general for the vp8 decoder im building
the first idea is that the streams are orgenized on a ring like fifo containing a contignous region and a ring region each of them is a partition by it self since the stream is sequential there exist only two partitions part_0 containing the frame and mb headers and part_1 containing the tokens since decoding needs both the headers and tokens to coexist the part_0 is not a ring buffer and since the size of part_0 is know from the first 10 bytes we can allocate enough memory dynamically keeping the other partitions (well only one partition for this implementation) been a ring buffer

#set align(center)
| 10 + part_0 | part_1 ring buffer |
#set align(left)

= decoding sequence
Since we need some context while decoding from the frame buffer we cant decode in any order that said the best order for maximum parallel decoding is a wavefront pattern keeping a one advanced block on each layer since for a block(i) we need context from the block(i - WMB + 1)
this makes it hard to have many parallel decoding at the same time also since the bit stream is sequential and on this implementation i support only one residuals (tokens) partition doing this in parallel is hard so the idea here is to have some say empty slots for decoding and each stage decode at its speed meaning the macroblock headers (layed on raster order) get decoded at its own speed for M macroblocks then the residuals for them also is getting decoded at its own speed for N residuals (layed on raster order) then we get an issue we need 2WMB empty slots to have parallel decoding, a solution for this to consider doing decoding in raster order for easy implementation and the performace gain is on the block decoding itself where wave front can be done for the 16 4x4 blocks on each macro block (for luma) and also the 4 4x4 blocks (for chroma) so we get all of this decoded in parallel then since decoding the macroblocks in parallel is bounded by the stream first, the number of slots available on the decoder wrt the WMB and the decoding spead for both macroblocks and tokens so even though technically its possible to parallelize this putting more effort parallelizing and optimizing the macroblock will have a significant performace boost on the whole codec

= Blocks handshaking
Following the new patterns of AXI lite interfacing, every exchanged signal on this core have a valid and ready and following standard practices none of them should be driven combinationally from other to prevent oscillations and wrong simulations and races on general. ready means the down stream is ready to recive the signal and valid mean the up stream have valid data for the down stream, valid is high until ready is high and ready is high whenever the module is watching for the valid signal.
this insure proper backpressure handling and making modules dont have asumptions about other modules.

= The syntax parsing
This part is the most triky part since handling syntax is fully sequential and result on a very complex FSMs, so to reduce boilerplate the syntax will be parsed on stages each stage responsible for a very specific part of the syntax.

