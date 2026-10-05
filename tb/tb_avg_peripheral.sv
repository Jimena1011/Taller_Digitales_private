`timescale 1ns/1ps

// Testbench autochequeo del periférico de promedio de 4 muestras.
// Valida el sistema completo (avg_peripheral_top) a través de la interfaz de bus.
module tb_avg_peripheral;

    // ---------------- Direcciones y valores esperados de estado ----------------
    localparam logic [1:0] ADDR_CTRL = 2'b00;
    localparam logic [1:0] ADDR_DATA = 2'b01;
    localparam logic [1:0] ADDR_RES  = 2'b10;

    localparam logic [31:0] ST_IDLE = 32'h0000_0000;  // busy=0, done=0
    localparam logic [31:0] ST_BUSY = 32'h0000_0002;  // busy=1, done=0
    localparam logic [31:0] ST_DONE = 32'h0000_0004;  // busy=0, done=1

    // ---------------- Señales del DUT ----------------
    logic        clk_i;
    logic        rst_i;
    logic        write_enable_i;
    logic [1:0]  addr_i;
    logic [31:0] wdata_i;
    logic [31:0] rdata_o;

    avg_peripheral_top dut (
        .clk_i          (clk_i),
        .rst_i          (rst_i),
        .write_enable_i (write_enable_i),
        .addr_i         (addr_i),
        .wdata_i        (wdata_i),
        .rdata_o        (rdata_o)
    );

    // ---------------- Reloj: 100 MHz ----------------
    initial clk_i = 1'b0;
    always #5 clk_i = ~clk_i;

    // ---------------- Contadores de resultados ----------------
    int errors = 0;
    int checks = 0;

    // ---------------- Tareas de bus ----------------
    // Las entradas cambian en el flanco de bajada; el DUT las muestrea en el de subida.

    task automatic bus_write(input logic [1:0] a, input logic [31:0] d);
        @(negedge clk_i);
        write_enable_i = 1'b1;
        addr_i         = a;
        wdata_i        = d;
        @(negedge clk_i);
        write_enable_i = 1'b0;
        wdata_i        = 32'h0;
    endtask

    task automatic bus_read(input logic [1:0] a, output logic [31:0] d);
        @(negedge clk_i);
        write_enable_i = 1'b0;
        addr_i         = a;
        #1;                      // rdata_o es combinacional respecto a addr_i
        d = rdata_o;
    endtask

    task automatic apply_reset;
        @(negedge clk_i);
        rst_i          = 1'b1;
        write_enable_i = 1'b0;
        @(negedge clk_i);        // un flanco de subida con rst_i=1
        rst_i          = 1'b0;
    endtask

    // ---------------- Chequeo ----------------
    task automatic check(input string msg, input logic [31:0] got, input logic [31:0] expected);
        checks++;
        if (got === expected)
            $display("[%0t] OK    %s: 0x%08h", $time, msg, got);
        else begin
            errors++;
            $display("[%0t] ERROR %s: obtenido 0x%08h, esperado 0x%08h", $time, msg, got, expected);
        end
    endtask

    task automatic check_status(input string msg, input logic [31:0] expected);
        logic [31:0] st;
        bus_read(ADDR_CTRL, st);
        check(msg, st, expected);
    endtask

    task automatic check_result(input string msg, input logic [31:0] expected);
        logic [31:0] r;
        bus_read(ADDR_RES, r);
        check(msg, r, expected);
    endtask

    // Inicia una acumulación: escribe 1 en el bit start del registro 0.
    task automatic start_calc;
        bus_write(ADDR_CTRL, 32'h0000_0001);
    endtask

    task automatic send_sample(input logic [31:0] s);
        bus_write(ADDR_DATA, s);
    endtask

    // ---------------- Estímulos ----------------
    initial begin
        rst_i          = 1'b0;
        write_enable_i = 1'b0;
        addr_i         = 2'b00;
        wdata_i        = 32'h0;

        // =====================================================================
        // Caso 1: cálculo completo del promedio con lectura correcta del resultado
        //   Muestras 0, 100, 200, 300 -> suma 600 -> promedio 150
        //   (la muestra 0 debe contar igual que cualquier otra)
        // =====================================================================
        $display("\n--- Caso 1: calculo completo ---");
        apply_reset();
        check_status("C1 estado tras reset", ST_IDLE);

        start_calc();
        check_status("C1 busy=1 tras start", ST_BUSY);

        send_sample(32'd0);
        check_status("C1 sigue busy tras muestra 1", ST_BUSY);
        send_sample(32'd100);
        send_sample(32'd200);
        check_status("C1 sigue busy tras muestra 3", ST_BUSY);
        send_sample(32'd300);

        check_status("C1 done=1 tras 4 muestras", ST_DONE);
        check_result("C1 promedio", 32'd150);
        check_result("C1 promedio estable (2da lectura)", 32'd150);

        // =====================================================================
        // Caso 2: escritura de muestra ignorada antes de start
        //   La muestra 999 llega en IDLE y no debe contar ni afectar el promedio.
        //   Luego 4, 8, 12, 16 -> suma 40 -> promedio 10
        // =====================================================================
        $display("\n--- Caso 2: muestra antes de start ---");
        apply_reset();
        send_sample(32'd999);
        check_status("C2 estado IDLE tras muestra ignorada", ST_IDLE);

        start_calc();
        send_sample(32'd4);
        send_sample(32'd8);
        send_sample(32'd12);
        check_status("C2 busy (solo 3 muestras validas)", ST_BUSY);
        send_sample(32'd16);
        check_status("C2 done tras 4 muestras validas", ST_DONE);
        check_result("C2 promedio (999 ignorada)", 32'd10);

        // =====================================================================
        // Caso 3: escritura de muestra ignorada después de done
        //   El resultado y done no deben cambiar.
        // =====================================================================
        $display("\n--- Caso 3: muestra despues de done ---");
        send_sample(32'd12345);
        check_status("C3 done se mantiene", ST_DONE);
        check_result("C3 promedio no cambia", 32'd10);
        send_sample(32'hFFFF_FFFF);
        check_status("C3 done se mantiene (2da escritura)", ST_DONE);
        check_result("C3 promedio no cambia (2da escritura)", 32'd10);

        // =====================================================================
        // Caso 4: reinicio del cálculo mediante un nuevo start
        // =====================================================================
        $display("\n--- Caso 4: nuevo start ---");
        // 4a: desde DONE, con muestras negativas: -8, -4, -12, -16 -> suma -40 -> promedio -10
        //     Un start escrito a mitad del cálculo (busy=1) debe ignorarse.
        start_calc();
        check_status("C4a done limpio y busy=1 tras nuevo start", ST_BUSY);
        send_sample(-32'sd8);
        send_sample(-32'sd4);
        start_calc();                       // debe ignorarse
        check_status("C4a start ignorado durante busy", ST_BUSY);
        send_sample(-32'sd12);
        check_status("C4a busy (3 muestras)", ST_BUSY);
        send_sample(-32'sd16);
        check_status("C4a done", ST_DONE);
        check_result("C4a promedio negativo", 32'hFFFF_FFF6);   // -10

        // 4b: segundo reinicio con 4 x 0x7FFFFFFF: la suma desborda 32 bits
        //     pero el promedio debe ser 0x7FFFFFFF.
        start_calc();
        check_status("C4b busy=1 tras nuevo start", ST_BUSY);
        send_sample(32'h7FFF_FFFF);
        send_sample(32'h7FFF_FFFF);
        send_sample(32'h7FFF_FFFF);
        send_sample(32'h7FFF_FFFF);
        check_status("C4b done", ST_DONE);
        check_result("C4b promedio sin desborde", 32'h7FFF_FFFF);

        // =====================================================================
        // Caso 5: comportamiento del reset síncrono durante un cálculo en curso
        // =====================================================================
        $display("\n--- Caso 5: reset durante calculo ---");
        start_calc();
        send_sample(32'd100);
        send_sample(32'd200);
        check_status("C5 busy antes del reset", ST_BUSY);

        apply_reset();
        check_status("C5 busy=0, done=0 tras reset", ST_IDLE);

        send_sample(32'd5555);              // en IDLE: debe ignorarse
        check_status("C5 muestra tras reset ignorada", ST_IDLE);

        // Nuevo cálculo completo: 40, 40, 40, 40 -> promedio 40.
        // Si el contador o el acumulador no se hubieran limpiado, el resultado sería otro.
        start_calc();
        send_sample(32'd40);
        send_sample(32'd40);
        send_sample(32'd40);
        check_status("C5 busy (3 muestras del nuevo calculo)", ST_BUSY);
        send_sample(32'd40);
        check_status("C5 done", ST_DONE);
        check_result("C5 promedio tras reset", 32'd40);

        // ---------------- Resumen ----------------
        $display("\n==============================================");
        if (errors == 0)
            $display("TODOS LOS CASOS PASARON (%0d chequeos)", checks);
        else
            $display("FALLARON %0d de %0d chequeos", errors, checks);
        $display("==============================================\n");
        $finish;
    end

    // ---------------- Watchdog ----------------
    initial begin
        #100000;
        $display("ERROR: timeout del testbench");
        $finish;
    end

endmodule
