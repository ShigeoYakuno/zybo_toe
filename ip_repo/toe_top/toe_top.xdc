## IP-level XDC for toe_top (OOC synthesis context)
## Only create_clock is valid here.
## PACKAGE_PIN, I/O timing, false paths, and bitstream settings
## belong in the project-level XDC (hdl/constrs/toe_top.xdc).

## LAN8720 REF_CLK 50 MHz input
create_clock -name ref_clk -period 20.000 [get_ports ref_clk]
