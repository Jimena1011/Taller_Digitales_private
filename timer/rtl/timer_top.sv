// Periférico temporizador programable (contador descendente de 32 bits).
// Top estructural: solo instancia y conecta los módulos.
module timer_top #(
    parameter int DIV_1KHZ = 10000   // 10 MHz / 1 kHz; se reduce en simulación
) (
    input  logic        clk_i,
    input  logic        reset_i,
    input  logic        write_i,
    input  logic        addr_i,
    input  logic [31:0] data_i,
    output logic [31:0] data_o,
    output logic        timeout_o
);

    // Decodificador de escritura -> registros
    logic wr_ctrl;
    logic wr_data;

    // Registro de control
    logic run;
    logic auto_reload;
    logic clk_sel;

    // Datapath
    logic [31:0] init;
    logic [31:0] cnt;
    logic        zero;
    logic        tick_1khz;
    logic        step;

    // FSM -> datapath
    logic load;
    logic dec_en;
    logic set_timeout;
    logic clr_timeout;
    logic clr_run;

    // ---------------- Control ----------------
    write_decoder u_write_decoder (
        .write_i   (write_i),
        .addr_i    (addr_i),
        .wr_ctrl_o (wr_ctrl),
        .wr_data_o (wr_data)
    );

    control_fsm u_control_fsm (
        .clk_i         (clk_i),
        .reset_i       (reset_i),
        .run_i         (run),
        .auto_reload_i (auto_reload),
        .step_i        (step),
        .zero_i        (zero),
        .load_o        (load),
        .dec_en_o      (dec_en),
        .set_timeout_o (set_timeout),
        .clr_timeout_o (clr_timeout),
        .clr_run_o     (clr_run)
    );

    // ---------------- Registros ----------------
    ctrl_reg u_ctrl_reg (
        .clk_i         (clk_i),
        .reset_i       (reset_i),
        .wr_ctrl_i     (wr_ctrl),
        .clr_run_i     (clr_run),
        .data_i        (data_i[2:0]),
        .run_o         (run),
        .auto_reload_o (auto_reload),
        .clk_sel_o     (clk_sel)
    );

    init_reg u_init_reg (
        .clk_i   (clk_i),
        .reset_i (reset_i),
        .en_i    (wr_data),
        .d_i     (data_i),
        .q_o     (init)
    );

    // timeout_o es directamente el flag; también alimenta el mux de lectura.
    timeout_flag u_timeout_flag (
        .clk_i   (clk_i),
        .reset_i (reset_i),
        .set_i   (set_timeout),
        .clr_i   (clr_timeout),
        .flag_o  (timeout_o)
    );

    // ---------------- Contador y base de tiempo ----------------
    down_counter u_down_counter (
        .clk_i    (clk_i),
        .reset_i  (reset_i),
        .load_i   (load),
        .dec_en_i (dec_en),
        .init_i   (init),
        .cnt_o    (cnt)
    );

    zero_detect u_zero_detect (
        .cnt_i  (cnt),
        .zero_o (zero)
    );

    clk_div #(.DIV(DIV_1KHZ)) u_clk_div (
        .clk_i   (clk_i),
        .reset_i (reset_i),
        .en_i    (run),
        .tick_o  (tick_1khz)
    );

    step_mux u_step_mux (
        .clk_sel_i (clk_sel),
        .tick_i    (tick_1khz),
        .step_o    (step)
    );

    // ---------------- Lectura ----------------
    read_mux u_read_mux (
        .addr_i          (addr_i),
        .timeout_flag_i  (timeout_o),
        .clk_sel_i       (clk_sel),
        .auto_reload_i   (auto_reload),
        .run_i           (run),
        .cnt_i           (cnt),
        .data_o          (data_o)
    );

endmodule
