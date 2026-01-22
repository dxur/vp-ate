# Chapter 1 General architecture
This is the general archetecture design of the vp8 decoder on hardware.
this implementation is intra only due to the time limitation and the fact
that this is a graduation project.

This IP core IO will be as simple as a bit stream input and a constructed frame output, the frame buffer will
be provided by the environment as an AXILite compatible memory, since this implemntation is intra only then no
need for DPB refrences.




