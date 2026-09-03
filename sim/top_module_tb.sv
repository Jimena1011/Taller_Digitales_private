`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: top_module_tb
// Description : Testbench para top_module (cerradura digital / password lock).
//
//   Interfaz del DUT:
//     input        clk
//     input        rst
//     output       unlock
//     input  [7:0] password
//
//   El testbench:
//     - Genera el reloj.
//     - Aplica un reset inicial.
//     - Prueba varias contraseñas (correcta e incorrectas).
//     - Monitorea la salida 'unlock' y reporta resultados.
//
//   Nota: la contraseña "correcta" se define abajo con CLAVE_OK. Ajústala al
//   valor real de tu diseño.
//////////////////////////////////////////////////////////////////////////////////

module top_module_tb;

    // --------------------------------------------------------------------------
    // Señales del testbench
    // --------------------------------------------------------------------------
    logic        clk;
    logic        rst;
    logic        unlock;
    logic [7:0]  password;

    // Contraseña esperada como correcta (ajústala a tu diseño)
    localparam logic [7:0] CLAVE_OK = 8'hA5;

    // Periodo de reloj: 10 ns -> 100 MHz
    localparam int PERIODO = 10;

    // Contadores de pruebas
    int pruebas   = 0;
    int fallidas  = 0;

    // --------------------------------------------------------------------------
    // Instancia del DUT (Device Under Test)
    // --------------------------------------------------------------------------
    top_module dut (
        .clk      (clk),
        .rst      (rst),
        .unlock   (unlock),
        .password (password)
    );

    // --------------------------------------------------------------------------
    // Generación de reloj
    // --------------------------------------------------------------------------
    initial clk = 1'b0;
    always #(PERIODO/2) clk = ~clk;

    // --------------------------------------------------------------------------
    // Tarea: reset síncrono/asíncrono
    // --------------------------------------------------------------------------
    task automatic aplicar_reset();
        begin
            rst      = 1'b1;
            password = 8'h00;
            repeat (3) @(posedge clk);
            rst = 1'b0;
            @(posedge clk);
        end
    endtask

    // --------------------------------------------------------------------------
    // Tarea: aplicar una contraseña y verificar la salida esperada de 'unlock'
    // --------------------------------------------------------------------------
    task automatic probar_clave(input logic [7:0] clave,
                                input logic        esperado);
        begin
            password = clave;
            // Espera algunos ciclos para que la FSM procese la entrada
            repeat (4) @(posedge clk);

            pruebas++;
            if (unlock === esperado) begin
                $display("[OK]   t=%0t  password=0x%02h  unlock=%b (esperado %b)",
                         $time, clave, unlock, esperado);
            end else begin
                fallidas++;
                $display("[FALLA] t=%0t  password=0x%02h  unlock=%b (esperado %b)",
                         $time, clave, unlock, esperado);
            end
        end
    endtask

    // --------------------------------------------------------------------------
    // Secuencia de estímulos
    // --------------------------------------------------------------------------
    initial begin
        $display("==== Inicio del testbench: top_module ====");

        // Estado inicial + reset
        aplicar_reset();

        // Tras el reset, la cerradura debe estar bloqueada
        pruebas++;
        if (unlock === 1'b0)
            $display("[OK]   t=%0t  unlock=%b tras reset (bloqueado)", $time, unlock);
        else begin
            fallidas++;
            $display("[FALLA] t=%0t  unlock=%b tras reset (se esperaba 0)", $time, unlock);
        end

        // Contraseñas incorrectas -> no debe abrir
        probar_clave(8'h00, 1'b0);
        probar_clave(8'h0F, 1'b0);
        probar_clave(8'hFF, 1'b0);

        // Contraseña correcta -> debe abrir
        probar_clave(CLAVE_OK, 1'b1);

        // Reset de nuevo y verificar que vuelve a bloquear
        aplicar_reset();
        probar_clave(8'h13, 1'b0);

        // --------------------------------------------------------------------
        // Resumen
        // --------------------------------------------------------------------
        $display("==== Fin del testbench ====");
        $display("Pruebas totales: %0d  |  Fallidas: %0d", pruebas, fallidas);
        if (fallidas == 0)
            $display(">>> TODAS LAS PRUEBAS PASARON <<<");
        else
            $display(">>> HAY %0d PRUEBAS FALLIDAS <<<", fallidas);

        $finish;
    end

    // --------------------------------------------------------------------------
    // Volcado de ondas (para GTKWave / visores de forma de onda)
    // --------------------------------------------------------------------------
    initial begin
        $dumpfile("top_module_tb.vcd");
        $dumpvars(0, top_module_tb);
    end

    // --------------------------------------------------------------------------
    // Watchdog: evita simulaciones infinitas
    // --------------------------------------------------------------------------
    initial begin
        #10000;
        $display("[TIMEOUT] Watchdog activado, finalizando simulación.");
        $finish;
    end

endmodule
