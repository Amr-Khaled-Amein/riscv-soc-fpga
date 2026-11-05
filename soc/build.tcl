# command line build, same thing as Run All in the IDE
# from the soc folder:  D:\gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe build.tcl

set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7

add_file src/top.v
add_file src/host_link.v
add_file src/soc.v
add_file src/rv_core.v
add_file src/rv_decode.v
add_file src/rv_alu.v
add_file src/rv_csr.v
add_file src/ram.v
add_file src/ram_lane.v
add_file src/axil_xbar.v
add_file src/axil_slave.v
add_file src/uart_axi.v
add_file src/timer_axi.v
add_file src/sys_axi.v
add_file src/fft_axi.v
add_file src/fft_core.v
add_file src/sample_ram.v
add_file src/twiddle_rom.v
add_file src/sdram_ctrl.v
add_file src/sdram_axi.v
add_file src/uart_tx.v
add_file src/uart_rx.v
add_file src/top.cst
add_file src/top.sdc

set_option -top_module top
set_option -output_base_name soc
set_option -verilog_std v2001

run all
