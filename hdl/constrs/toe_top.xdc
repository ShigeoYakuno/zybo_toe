## ============================================================================
## ZYBO Z7-20  +  Waveshare LAN8720 ETH Board
## Target: xc7z020clg400-1
##
## Wiring (user-defined):
##   JC1_P V15  -> TX0   (rmii_txd[0])
##   JC1_N W15  -> RX1   (rmii_rxd[1])
##   JC2_P T11  -> CRS   (rmii_crs_dv)
##   JC2_N T10  -> MDC   (mdc)
##   JC3_P W14  -> TX-EN (rmii_tx_en)
##   JC3_N Y14  -> RX0   (rmii_rxd[0])
##   JC4_P T12  -> INT/RETCLK -> ref_clk 50 MHz
##   JC4_N U12  -> MDIO  (mdio)
##   JB2_N V7   -> TX1   (rmii_txd[1])
## ============================================================================

## ---------------------------------------------------------------------------
## Clock: LAN8720 INT/RETCLK 50 MHz -> T12 (IO_L2P_T0_35, non-CCIO)
## ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN T12 IOSTANDARD LVCMOS33} [get_ports ref_clk]
create_clock -name ref_clk -period 20.000 [get_ports ref_clk]

## T12 is not a Clock-Capable IO. Allow non-dedicated BUFG route at 50 MHz.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets ref_clk_IBUF]

## 非CCIOルーティングによる追加遅延 (~3ns) をタイミング解析に反映させる。
## これにより Vivado が RMII TX 出力パスをより厳密にタイミング解析する。
## (CLOCK_DEDICATED_ROUTE FALSE だとこの遅延が解析に含まれない可能性がある)
set_clock_latency -source 3.000 [get_clocks ref_clk]

## ---------------------------------------------------------------------------
## RMII TX
## ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports {rmii_txd[0]}]
set_property -dict {PACKAGE_PIN V7 IOSTANDARD LVCMOS33} [get_ports {rmii_txd[1]}]
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports rmii_tx_en]

## ---------------------------------------------------------------------------
## RMII RX
## ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33} [get_ports {rmii_rxd[0]}]
set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVCMOS33} [get_ports {rmii_rxd[1]}]
set_property -dict {PACKAGE_PIN T11 IOSTANDARD LVCMOS33} [get_ports rmii_crs_dv]

## ---------------------------------------------------------------------------
## MDIO management
## ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports mdc]
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33} [get_ports mdio]

## ---------------------------------------------------------------------------
## Timing exceptions: ref_clk and PS clocks are asynchronous.
## ---------------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks ref_clk] \
    -group [get_clocks -filter {NAME != ref_clk} -quiet]

## ---------------------------------------------------------------------------
## I/O timing
## LAN8720A RMII: setup = 4ns, PCB trace ~0.5ns → output_delay_max = 4.5ns
## Using 4.0ns gives +3.3ns margin after slow-corner analysis.
## ---------------------------------------------------------------------------
set_output_delay -clock ref_clk -max  4.0 [get_ports {rmii_txd[*] rmii_tx_en}]
set_output_delay -clock ref_clk -min -2.0 [get_ports {rmii_txd[*] rmii_tx_en}]
set_input_delay  -clock ref_clk -max  6.0 [get_ports {rmii_rxd[*] rmii_crs_dv}]
set_input_delay  -clock ref_clk -min  0.0 [get_ports {rmii_rxd[*] rmii_crs_dv}]

## RMII TX: fast slew to reduce OBUF propagation delay (~1ns improvement)
set_property SLEW FAST [get_ports {rmii_txd[*] rmii_tx_en}]
set_property DRIVE 8   [get_ports {rmii_txd[*] rmii_tx_en}]

## IOB TRUE は非CCIOクロック(T12, CLOCK_DEDICATED_ROUTE FALSE)では
## クロックがIOBフロップに届かず配置エラーになるため削除。


set_property -dict { PACKAGE_PIN M14   IOSTANDARD LVCMOS33 } [get_ports { led_tri_o[0] }];
set_property -dict { PACKAGE_PIN M15   IOSTANDARD LVCMOS33 } [get_ports { led_tri_o[1] }];
set_property -dict { PACKAGE_PIN G14   IOSTANDARD LVCMOS33 } [get_ports { led_tri_o[2] }];
set_property -dict { PACKAGE_PIN D18   IOSTANDARD LVCMOS33 } [get_ports { led_tri_o[3] }];


# sens(JDコネクタ)
set_property PACKAGE_PIN T14 [get_ports iic_sens_scl_io]   ; # JD1_P
set_property PACKAGE_PIN T15 [get_ports iic_sens_sda_io]     ; # JD1_N  
set_property IOSTANDARD LVCMOS33 [get_ports iic_sens_scl_io]
set_property IOSTANDARD LVCMOS33 [get_ports iic_sens_sda_io]

## ---------------------------------------------------------------------------
## Bitstream settings
## ---------------------------------------------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
