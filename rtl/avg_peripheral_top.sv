// Periférico de promedio de 4 muestras de 32 bits.
// Top estructural: solo instancia y conecta los módulos.
module avg_peripheral_top (
    input  logic        clk_i,
    input  logic        rst_i,
    input  logic        write_enable_i,
    input  logic [1:0]  addr_i,
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o
);

    localparam int ACC_W = 34;  // 32 bits + 2 para evitar desborde en la suma de 4 muestras

    // Decodificador de escritura -> FSM
    logic start_pulse;
    logic sample_pulse;

    // FSM -> datapath y mux de lectura
    logic busy;
    logic done;
    logic clr;
    logic acc_en;

    // Datapath
    logic [ACC_W-1:0] sample_ext;
    logic [ACC_W-1:0] sum;
    logic [ACC_W-1:0] acc;
    logic [1:0]       cnt;
    logic             last;
    logic [31:0]      avg;

    // ---------------- Control ----------------
    write_decoder u_write_decoder (
        .we_i           (write_enable_i),
        .addr_i         (addr_i),
        .wdata0_i       (wdata_i[0]),
        .start_pulse_o  (start_pulse),
        .sample_pulse_o (sample_pulse)
    );

    control_fsm u_control_fsm (
        .clk_i          (clk_i),
        .rst_i          (rst_i),
        .start_pulse_i  (start_pulse),
        .sample_pulse_i (sample_pulse),
        .last_i         (last),
        .busy_o         (busy),
        .done_o         (done),
        .clr_o          (clr),
        .acc_en_o       (acc_en)
    );

    // ---------------- Datapath ----------------
    sign_extend u_sign_extend (
        .d_i (wdata_i),
        .d_o (sample_ext)
    );

    adder #(.WIDTH(ACC_W)) u_adder (
        .a_i   (acc),
        .b_i   (sample_ext),
        .sum_o (sum)
    );

    acc_reg #(.WIDTH(ACC_W)) u_acc_reg (
        .clk_i (clk_i),
        .rst_i (rst_i),
        .clr_i (clr),
        .en_i  (acc_en),
        .d_i   (sum),
        .q_o   (acc)
    );

    sample_counter u_sample_counter (
        .clk_i (clk_i),
        .rst_i (rst_i),
        .clr_i (clr),
        .en_i  (acc_en),
        .cnt_o (cnt)
    );

    last_detect u_last_detect (
        .cnt_i  (cnt),
        .last_o (last)
    );

    avg_shift u_avg_shift (
        .acc_i (acc),
        .avg_o (avg)
    );

    // ---------------- Lectura ----------------
    read_mux u_read_mux (
        .addr_i  (addr_i),
        .busy_i  (busy),
        .done_i  (done),
        .avg_i   (avg),
        .rdata_o (rdata_o)
    );

endmodule
