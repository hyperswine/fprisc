set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7
set_option -top_module top
set_option -output_base_name sdram_test
set_option -opt_goal timing
set_option -place_option 2
set_option -frequency 48
set_option -global_freq 48
set_option -num_critical_paths 20
set_option -gen_verilog_sim_netlist 1
add_file "/Users/jasonqin/Documents/GitHub/HaskPlayground/output/tangnano20k/gc-validation-c48-20261020/pipeline_top.v"
add_file "/Users/jasonqin/Documents/GitHub/HaskPlayground/output/tangnano20k/gc-validation-c48-20261020/memory.v"
add_file "/Users/jasonqin/Documents/GitHub/HaskPlayground/boards/tangnano20k/sdram/cache.v"
add_file "/Users/jasonqin/Documents/GitHub/HaskPlayground/boards/tangnano20k/sdram/pipeline_cache.v"
add_file "/Users/jasonqin/Documents/GitHub/HaskPlayground/boards/tangnano20k/sdram/burst_memory.v"
add_file "/Users/jasonqin/Documents/GitHub/HaskPlayground/boards/tangnano20k/sdram/clock_bridge.v"
add_file "/Users/jasonqin/Documents/GitHub/HaskPlayground/boards/tangnano20k/sdram/sdram.v"
add_file "/Users/jasonqin/Documents/GitHub/HaskPlayground/output/tangnano20k/gc-validation-c48-20261020/pll.v"
add_file "/Users/jasonqin/Documents/GitHub/HaskPlayground/boards/tangnano20k/sdram/dual_pll.v"
add_file "/Users/jasonqin/Documents/GitHub/HaskPlayground/output/tangnano20k/gc-validation-c48-20261020/pins.cst"
add_file "/Users/jasonqin/Documents/GitHub/HaskPlayground/output/tangnano20k/gc-validation-c48-20261020/clocks.sdc"
file delete -force "/Users/jasonqin/Documents/GitHub/HaskPlayground/output/tangnano20k/gc-validation-c48-20261020/impl/pnr/sdram_test.tr"
add_file "/Users/jasonqin/Documents/GitHub/HaskPlayground/output/tangnano20k/sdram-generated/SdramPipeline-1/SdramPipeline.topEntity/sdram_pipeline_risc.v"
run all
exit
