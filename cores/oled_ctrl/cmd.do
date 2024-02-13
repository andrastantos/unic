#create_project -name TTT -pn GW1NR-LV4QN88C6/I5 -device_version D
set_device GW1NR-LV4QN88C6/I5 -device_version D
add_file top.sv
add_file oled_ctrl.sv
add_file pin_constraints.cst
set_option -verilog_std sysv2017
set_option -gen_text_timing_rpt 1
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
run all
