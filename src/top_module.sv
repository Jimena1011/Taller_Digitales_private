`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: top_module
// Description : Cerradura digital (password lock).
//
//   Se desbloquea (unlock = 1) cuando la contraseña ingresada coincide con la
//   clave almacenada (CLAVE). Permanece desbloqueada durante LIMITE ciclos de
//   reloj y luego vuelve a bloquearse (timeout). El reset la bloquea siempre.
//
//   Estructura modular:
//     - comparador : compara 'password' contra la clave.
//     - contador   : mide el tiempo que permanece abierta y genera 'timeout'.
//     - fsm        : máquina de estados que controla el desbloqueo.
//
//   Interfaz:
//     input        clk
//     input        rst
//     output       unlock
//     input  [7:0] password
//////////////////////////////////////////////////////////////////////////////////


// =============================================================================
// Comparador: clave_ok = 1 cuando la contraseña coincide con la clave
// =============================================================================
module comparador #(
    parameter logic [7:0] CLAVE = 8'hA5
)(
    input  logic [7:0] password,
    output logic       clave_ok
);
    assign clave_ok = (password == CLAVE);
endmodule


// =============================================================================
// Contador: mientras 'enable' esté activo cuenta ciclos de reloj; cuando
// alcanza LIMITE activa 'timeout'. Se reinicia con rst o cuando enable=0.
// =============================================================================
module contador #(
    parameter int LIMITE = 20
)(
    input  logic clk,
    input  logic rst,
    input  logic enable,
    output logic timeout
);
    localparam int W = (LIMITE < 2) ? 1 : $clog2(LIMITE + 1);
    logic [W-1:0] cuenta;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            cuenta  <= '0;
            timeout <= 1'b0;
        end else if (enable) begin
            if (cuenta >= LIMITE[W-1:0]) begin
                timeout <= 1'b1;
            end else begin
                cuenta  <= cuenta + 1'b1;
                timeout <= 1'b0;
            end
        end else begin
            cuenta  <= '0;
            timeout <= 1'b0;
        end
    end
endmodule


// =============================================================================
// FSM: controla el bloqueo/desbloqueo de la cerradura.
//   S_LOCKED   : bloqueado, unlock=0. Si clave_ok -> S_UNLOCKED.
//   S_UNLOCKED : desbloqueado, unlock=1. Si timeout -> S_LOCKED.
// =============================================================================
module fsm (
    input  logic       clk,
    input  logic       rst,
    input  logic       clave_ok,
    input  logic       timeout,
    output logic       unlock,
    output logic [2:0] state
);
    typedef enum logic [2:0] {
        S_LOCKED   = 3'b001,
        S_UNLOCKED = 3'b010
    } estado_t;

    estado_t estado, prox;

    // Registro de estado
    always_ff @(posedge clk or posedge rst) begin
        if (rst) estado <= S_LOCKED;
        else     estado <= prox;
    end

    // Lógica de próximo estado
    always_comb begin
        prox = estado;
        case (estado)
            S_LOCKED:   if (clave_ok) prox = S_UNLOCKED;
            S_UNLOCKED: if (timeout)  prox = S_LOCKED;
            default:    prox = S_LOCKED;
        endcase
    end

    // Salidas
    assign unlock = (estado == S_UNLOCKED);
    assign state  = estado;
endmodule


// =============================================================================
// Top: interconexión de comparador + contador + fsm
// =============================================================================
module top_module #(
    parameter logic [7:0] CLAVE  = 8'hA5,
    parameter int         LIMITE = 20
)(
    input  logic       clk,
    input  logic       rst,
    output logic       unlock,
    input  logic [7:0] password
);

    // Señales internas
    logic       clave_ok;    // salida del comparador
    logic       timeout;     // salida del contador
    logic       unlock_int;  // salida de la fsm
    logic [2:0] state;       // estado actual de la fsm

    // Instancia del comparador
    comparador #(.CLAVE(CLAVE)) u_comparador (
        .password (password),
        .clave_ok (clave_ok)
    );

    // Instancia del contador (habilitado mientras la cerradura está abierta)
    contador #(.LIMITE(LIMITE)) u_contador (
        .clk     (clk),
        .rst     (rst),
        .enable  (unlock_int),
        .timeout (timeout)
    );

    // Instancia de la máquina de estados
    fsm u_fsm (
        .clk      (clk),
        .rst      (rst),
        .clave_ok (clave_ok),
        .timeout  (timeout),
        .unlock   (unlock_int),
        .state    (state)
    );

    // Salida
    assign unlock = unlock_int;

endmodule
