derive_pll_clocks
derive_clock_uncertainty

# ============================================================================
# China Gate — core specific timing constraints
# ============================================================================
# clk_sys = 96 MHz (10.416 ns).
# CPU pin clock = clk_sys/16 = 6 MHz (cpu_cen). 6809 cycle E = 1.5 MHz.
# Path BRAM_porta(write CPU @ cen_Q) -> mc6809i registers (read @ cen_E):
# CPU scrive BRAM 1 ogni 16 cicli clk_sys, mc6809i campiona dato sul cen_E
# successivo (almeno 8 cicli dopo). Setup window reale = 16 cicli.
# ============================================================================

# pll_audio non collegato (audio non integrato): false_path elimina rumore -87ns
set_false_path -from [get_clocks {pll_audio|*|divclk}]
set_false_path -to   [get_clocks {pll_audio|*|divclk}]

# Multicycle 16/15 sui path CPU-paced BRAM porta_we_reg -> mc6809i.
# Pattern get_registers matcha i nomi registro che appaiono nel report STA:
#   *|altsyncram*|ram_block*~porta_we_reg
set_multicycle_path -setup -end 16 \
    -from [get_registers {*altsyncram*ram_block*~port?_we_reg*}] \
    -to   [get_registers {*mc6809i:u_cpu|*}]
set_multicycle_path -hold  -end 15 \
    -from [get_registers {*altsyncram*ram_block*~port?_we_reg*}] \
    -to   [get_registers {*mc6809i:u_cpu|*}]

# Multicycle 16/15 sui path interni mc6809i.
# Tutti i registri interni mc6809i (Inst1/2/3, a, b, x, y, s, u, cc, dp, pc,
# tmp, addr, ea, CpuState, NMI*, IRQ*, FIRQ*, HALT*, DMABREQ*, OP) sono
# aggiornati esclusivamente su cen_E o cen_Q (cen_div ÷16). Setup window
# reale tra qualsiasi coppia di registri mc6809i = 16 cicli clk_sys.
set_multicycle_path -setup -end 16 \
    -from [get_registers {*mc6809i:u_cpu|*}] \
    -to   [get_registers {*mc6809i:u_cpu|*}]
set_multicycle_path -hold  -end 15 \
    -from [get_registers {*mc6809i:u_cpu|*}] \
    -to   [get_registers {*mc6809i:u_cpu|*}]

# Multicycle 16/15 sui path mc6809i -> rom_cache_8bit.
# La CPU pilota cpu_addr (registri mc6809i) che entra in rom_cache_8bit per
# decode/hit-check e produce cpu_data. Anche se cpu_data è aggiornato su
# posedge clk libero, viene letto dalla CPU solo su cen_E successivo.
# Setup window reale = 16 cicli clk_sys.
set_multicycle_path -setup -end 16 \
    -from [get_registers {*mc6809i:u_cpu|*}] \
    -to   [get_registers {*rom_cache_8bit:*|*}]
set_multicycle_path -hold  -end 15 \
    -from [get_registers {*mc6809i:u_cpu|*}] \
    -to   [get_registers {*rom_cache_8bit:*|*}]

# Multicycle 16/15 sui path rom_cache_8bit -> mc6809i (verso CPU).
# cpu_data del cache è aggiornato su posedge clk libero, ma campionato dalla CPU
# solo su cen_E (1 ogni 16 ck). Setup window reale = 16 cicli clk_sys.
set_multicycle_path -setup -end 16 \
    -from [get_registers {*rom_cache_8bit:*|*}] \
    -to   [get_registers {*mc6809i:u_cpu|*}]
set_multicycle_path -hold  -end 15 \
    -from [get_registers {*rom_cache_8bit:*|*}] \
    -to   [get_registers {*mc6809i:u_cpu|*}]

# Multicycle 16/15 sui path mc6809i -> jtcg_main I/O latch (CPU pacing certi).
# Solo registri scritti dentro `if (w_3eXX)` o `if (w_3fXX)` con we_pulse=cpu_we&cen_q,
# o set/clear da pulsi pxl_cen-gated (vbl_nmi_set/timer_firq_set).
# ESCLUSI: snd_irq, sub_irq_set (default-low ogni ck, non pacing).
set_multicycle_path -setup -end 16 \
    -from [get_registers {*mc6809i:u_cpu|*}] \
    -to   [get_registers {*jtcg_main:u_main|scrollx_lo[*] *jtcg_main:u_main|scrolly_lo[*] *jtcg_main:u_main|scrollx_hi *jtcg_main:u_main|scrolly_hi *jtcg_main:u_main|flip_screen *jtcg_main:u_main|video_enable *jtcg_main:u_main|rom_bank[*] *jtcg_main:u_main|snd_latch[*] *jtcg_main:u_main|nmi_q *jtcg_main:u_main|firq_q *jtcg_main:u_main|irq_q}]
set_multicycle_path -hold  -end 15 \
    -from [get_registers {*mc6809i:u_cpu|*}] \
    -to   [get_registers {*jtcg_main:u_main|scrollx_lo[*] *jtcg_main:u_main|scrolly_lo[*] *jtcg_main:u_main|scrollx_hi *jtcg_main:u_main|scrolly_hi *jtcg_main:u_main|flip_screen *jtcg_main:u_main|video_enable *jtcg_main:u_main|rom_bank[*] *jtcg_main:u_main|snd_latch[*] *jtcg_main:u_main|nmi_q *jtcg_main:u_main|firq_q *jtcg_main:u_main|irq_q}]

# Multicycle 16/15 sui path mc6809i -> jtcg_sub.rom_bank (CPU pacing certo).
# ESCLUSO: jtcg_sub.irq_q (passa per sub_irq_set non gated).
set_multicycle_path -setup -end 16 \
    -from [get_registers {*mc6809i:u_cpu|*}] \
    -to   [get_registers {*jtcg_sub:u_sub|rom_bank[*]}]
set_multicycle_path -hold  -end 15 \
    -from [get_registers {*mc6809i:u_cpu|*}] \
    -to   [get_registers {*jtcg_sub:u_sub|rom_bank[*]}]

# Multicycle 16/15 sui path dip_sw -> mc6809i.
# dip_sw è caricato da ioctl_wr una volta all'avvio e poi resta statico.
# mc6809i.D viene campionato solo su cen_E (1 ogni 16 ck). Setup window reale = 16.
set_multicycle_path -setup -end 16 \
    -from [get_registers {*emu|dip_sw[*]}] \
    -to   [get_registers {*mc6809i:u_cpu|*}]
set_multicycle_path -hold  -end 15 \
    -from [get_registers {*emu|dip_sw[*]}] \
    -to   [get_registers {*mc6809i:u_cpu|*}]

# Multicycle 16/15 sui path hps_io -> mc6809i.
# hps_io.cfg e joystick_0/1 sono registri statici (cambiano molto raramente,
# solo su cmd HPS). mc6809i.D campionato solo su cen_E. Setup window reale = 16.
set_multicycle_path -setup -end 16 \
    -from [get_registers {*hps_io:u_hps_io|*}] \
    -to   [get_registers {*mc6809i:u_cpu|*}]
set_multicycle_path -hold  -end 15 \
    -from [get_registers {*hps_io:u_hps_io|*}] \
    -to   [get_registers {*mc6809i:u_cpu|*}]
