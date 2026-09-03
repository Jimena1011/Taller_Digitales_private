`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: top_module
// Description : Integra el comparador, el contador y la FSM de un cerrojo digital.
//               El usuario introduce una contraseña de 8 bits y, si es correcta,
//               se activa la salida `unlock`.
//////////////////////////////////////////////////////////////////////////////////

module top_module (
    input  logic       clk,        // Reloj del sistema
    input  logic       rst,        // Reinicio síncrono/asíncrono
    input  logic [7:0] password,   // Contraseña ingresada (bus de 8 bits)
    output logic       unlock      // Se activa cuando la contraseña es correcta
);

    // -----------------------------------------------------------------------
    // Señales internas que interconectan los submódulos.
    // (clk y rst NO se redeclaran: ya son puertos del módulo.)
    // -----------------------------------------------------------------------
    logic       inputkey;    // Habilitación/pulso de captura generado por la FSM
    logic       sig_unlock;  // Resultado de la comparación (contraseña correcta)
    logic       timeout;     // Indica que el contador llegó a su límite
    logic [2:0] state;       // Estado actual de la FSM

    // -----------------------------------------------------------------------
    // Comparador: compara la contraseña ingresada contra la de referencia
    // cuando la FSM lo habilita (inputkey) y genera sig_unlock.
    // -----------------------------------------------------------------------
    comparador u_comparador (
        .clk        (clk),
        .rst        (rst),
        .password   (password),
        .inputkey   (inputkey),
        .sig_unlock (sig_unlock)
    );

    // -----------------------------------------------------------------------
    // Contador: mide el tiempo disponible y avisa a la FSM con `timeout`.
    // -----------------------------------------------------------------------
    contador u_contador (
        .clk     (clk),
        .rst     (rst),
        .timeout (timeout)
    );

    // -----------------------------------------------------------------------
    // FSM: máquina de estados que controla el flujo. Recibe el resultado del
    // comparador (sig_unlock) y el timeout, y genera inputkey y el estado.
    // -----------------------------------------------------------------------
    fsm u_fsm (
        .clk        (clk),
        .rst        (rst),
        .sig_unlock (sig_unlock),
        .timeout    (timeout),
        .inputkey   (inputkey),
        .state      (state)
    );

    // -----------------------------------------------------------------------
    // Salida del sistema: se abre el cerrojo cuando el comparador valida.
    // -----------------------------------------------------------------------
    assign unlock = sig_unlock;

endmodule
