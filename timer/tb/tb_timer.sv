`timescale 1ns/1ps

// Testbench autochequeo del periférico temporizador programable.
// Valida el sistema completo (timer_top) a través de la interfaz de bus.
// Usa DIV_1KHZ reducido para poder simular el modo lento (1 kHz) en pocos ciclos.
module tb_timer;

    localparam int DIV = 4;     // en hardware real: 10000 (10 MHz / 1 kHz)

    localparam logic ADDR_CTRL = 1'b0;
    localparam logic ADDR_DATA = 1'b1;

    // Bits del registro de control / estado
    localparam logic [31:0] RUN  = 32'h0000_0001;
    localparam logic [31:0] AUTO = 32'h0000_0002;   // AUTO_RELOAD
    localparam logic [31:0] FAST = 32'h0000_0004;   // CLK_SEL=1 (10 MHz)
    localparam logic [31:0] FLAG = 32'h0000_0008;   // TIMEOUT_FLAG (solo lectura)

    // ---------------- Señales del DUT ----------------
    logic        clk_i;
    logic        reset_i;
    logic        write_i;
    logic        addr_i;
    logic [31:0] data_i;
    logic [31:0] data_o;
    logic        timeout_o;

    timer_top #(.DIV_1KHZ(DIV)) dut (
        .clk_i     (clk_i),
        .reset_i   (reset_i),
        .write_i   (write_i),
        .addr_i    (addr_i),
        .data_i    (data_i),
        .data_o    (data_o),
        .timeout_o (timeout_o)
    );

    // ---------------- Reloj: 10 MHz ----------------
    initial clk_i = 1'b0;
    always #50 clk_i = ~clk_i;

    int cyc = 0;                          // ciclos de reloj transcurridos
    always @(posedge clk_i) cyc++;

    int errors = 0;
    int checks = 0;

    // ---------------- Tareas de bus ----------------
    // Las entradas cambian en el flanco de bajada; el DUT las muestrea en el de subida.

    task automatic bus_write(input logic a, input logic [31:0] d);
        @(negedge clk_i);
        write_i = 1'b1;
        addr_i  = a;
        data_i  = d;
        @(negedge clk_i);
        write_i = 1'b0;
        data_i  = 32'h0;
    endtask

    task automatic bus_read(input logic a, output logic [31:0] d);
        @(negedge clk_i);
        write_i = 1'b0;
        addr_i  = a;
        #1;                      // data_o es combinacional respecto a addr_i
        d = data_o;
    endtask

    task automatic apply_reset;
        @(negedge clk_i);
        reset_i = 1'b1;
        write_i = 1'b0;
        @(negedge clk_i);
        reset_i = 1'b0;
    endtask

    // ---------------- Chequeos ----------------
    task automatic check(input string msg, input logic [31:0] got, input logic [31:0] expected);
        checks++;
        if (got === expected)
            $display("[%0t] OK    %s: 0x%08h", $time, msg, got);
        else begin
            errors++;
            $display("[%0t] ERROR %s: obtenido 0x%08h, esperado 0x%08h", $time, msg, got, expected);
        end
    endtask

    task automatic check_true(input string msg, input bit cond);
        checks++;
        if (cond)
            $display("[%0t] OK    %s", $time, msg);
        else begin
            errors++;
            $display("[%0t] ERROR %s", $time, msg);
        end
    endtask

    // ---------------- Utilidades del timer ----------------
    int t0 = 0;           // ciclo en que terminó la escritura que inició la cuenta
    int elapsed = 0;      // ciclos transcurridos hasta el timeout

    // Escribe el registro de control (inicia la cuenta si RUN=1) y marca t0.
    task automatic start_timer(input logic [31:0] ctrl);
        bus_write(ADDR_CTRL, ctrl);
        t0 = cyc;
    endtask

    // Espera a que timeout_o suba, con un máximo de ciclos desde t0.
    task automatic wait_timeout(input int max_cycles);
        while (timeout_o !== 1'b1 && (cyc - t0) < max_cycles)
            @(negedge clk_i);
        elapsed = cyc - t0;
        check_true($sformatf("timeout_o subio (a los %0d ciclos)", elapsed), timeout_o === 1'b1);
    endtask

    // ---------------- Estímulos ----------------
    logic [31:0] r, c, c1, c2, prev, first, maxv;
    int          i, reloads, decs, last_dec;

    initial begin
        reset_i = 1'b0;
        write_i = 1'b0;
        addr_i  = 1'b0;
        data_i  = 32'h0;

        // =====================================================================
        // Caso 1: estado después del reset
        // =====================================================================
        $display("\n--- Caso 1: estado tras reset ---");
        apply_reset();
        bus_read(ADDR_CTRL, r);  check("C1 control en 0", r, 32'h0);
        bus_read(ADDR_DATA, r);  check("C1 contador en 0", r, 32'h0);
        check("C1 timeout_o=0", {31'b0, timeout_o}, 32'h0);

        // =====================================================================
        // Caso 2: lectura/escritura del registro de control
        //   AUTO_RELOAD y CLK_SEL son R/W; TIMEOUT_FLAG y reservados no se escriben.
        // =====================================================================
        $display("\n--- Caso 2: registro de control ---");
        bus_write(ADDR_CTRL, AUTO | FAST);               // RUN=0: no inicia
        bus_read(ADDR_CTRL, r);  check("C2 escribe AUTO_RELOAD y CLK_SEL", r, AUTO | FAST);
        bus_write(ADDR_CTRL, 32'hFFFF_FFF8);             // bits 2:0 en 0; bit 3 y reservados ignorados
        bus_read(ADDR_CTRL, r);  check("C2 bit 3 y reservados no se escriben", r, 32'h0);
        bus_write(ADDR_DATA, 32'h0000_00FF);             // escribir datos no toca el control
        bus_read(ADDR_CTRL, r);  check("C2 escribir datos no cambia el control", r, 32'h0);
        check("C2 timeout_o sigue en 0", {31'b0, timeout_o}, 32'h0);

        // =====================================================================
        // Caso 3: modo rápido, sin AUTO_RELOAD
        //   Valor inicial 5: llega a cero, activa timeout, baja RUN y se detiene.
        // =====================================================================
        $display("\n--- Caso 3: modo rapido sin auto-reload ---");
        apply_reset();
        bus_write(ADDR_DATA, 32'd5);
        start_timer(RUN | FAST);
        wait_timeout(30);
        check_true("C3 tiempo hasta timeout coherente con valor inicial 5",
                   elapsed >= 5 && elapsed <= 5 + 6);
        bus_read(ADDR_CTRL, r);  check("C3 RUN en 0, CLK_SEL=1, flag=1", r, FAST | FLAG);
        bus_read(ADDR_DATA, r);  check("C3 contador en 0", r, 32'h0);
        repeat (20) @(negedge clk_i);
        bus_read(ADDR_CTRL, r);  check("C3 sigue detenido con flag", r, FAST | FLAG);
        bus_read(ADDR_DATA, r);  check("C3 contador sigue en 0", r, 32'h0);
        check("C3 timeout_o sigue en 1", {31'b0, timeout_o}, 32'h1);

        // =====================================================================
        // Caso 4: leer el registro de datos no interrumpe la cuenta
        // =====================================================================
        $display("\n--- Caso 4: lectura durante la cuenta ---");
        apply_reset();
        bus_write(ADDR_DATA, 32'd20);
        start_timer(RUN | FAST);
        prev  = 32'd21;
        first = 32'd0;
        for (i = 0; i < 8; i++) begin
            bus_read(ADDR_DATA, c);
            if (i == 0) first = c;
            check_true($sformatf("C4 lectura %0d: contador=%0d no sube", i, c), c <= prev && c <= 32'd20);
            prev = c;
        end
        check_true("C4 el contador decrementa mientras se lee", prev < first);
        wait_timeout(60);
        check_true("C4 las lecturas no retrasaron el timeout", elapsed >= 20 && elapsed <= 20 + 8);

        // =====================================================================
        // Caso 5: escribir el registro de datos durante la cuenta no la afecta;
        //         el nuevo valor se usa en el siguiente inicio;
        //         un nuevo inicio limpia el flag; RUN=0 detiene y conserva el contador.
        // =====================================================================
        $display("\n--- Caso 5: escritura durante la cuenta ---");
        apply_reset();
        bus_write(ADDR_DATA, 32'd30);
        start_timer(RUN | FAST);
        repeat (5) @(negedge clk_i);
        bus_read(ADDR_DATA, c1);
        bus_write(ADDR_DATA, 32'd100);                   // no debe afectar la cuenta en progreso
        bus_read(ADDR_DATA, c2);
        check_true($sformatf("C5 cuenta continua (%0d -> %0d), sin salto a 100", c1, c2),
                   c2 < c1 && c2 <= 32'd30);
        wait_timeout(80);
        check_true("C5 termina con el valor inicial viejo (30), no con 100", elapsed >= 30 && elapsed <= 30 + 8);

        start_timer(RUN | FAST);                         // nueva cuenta con el valor 100
        repeat (2) @(negedge clk_i);
        check("C5 nuevo inicio limpia timeout_o", {31'b0, timeout_o}, 32'h0);
        bus_read(ADDR_CTRL, r);
        check_true("C5 nuevo inicio limpia el bit TIMEOUT_FLAG", (r & FLAG) == 32'h0);
        bus_read(ADDR_DATA, c);
        check_true($sformatf("C5 cuenta nueva usa el valor 100 (contador=%0d)", c), c >= 32'd90 && c <= 32'd100);

        bus_write(ADDR_CTRL, FAST);                      // RUN=0: detiene
        bus_read(ADDR_DATA, c1);
        repeat (3) @(negedge clk_i);
        bus_read(ADDR_DATA, c2);
        check("C5 RUN=0 conserva el contador", c2, c1);

        // =====================================================================
        // Caso 6: modo rápido con AUTO_RELOAD
        //   Al llegar a cero recarga el valor inicial y continúa.
        // =====================================================================
        $display("\n--- Caso 6: auto-reload ---");
        apply_reset();
        bus_write(ADDR_DATA, 32'd6);
        start_timer(RUN | AUTO | FAST);
        wait_timeout(30);
        check_true("C6 primer timeout coherente con valor inicial 6", elapsed >= 6 && elapsed <= 6 + 6);
        bus_read(ADDR_CTRL, r);  check("C6 RUN sigue en 1 y flag=1", r, RUN | AUTO | FAST | FLAG);

        reloads = 0;  maxv = 32'd0;  prev = 32'd0;
        for (i = 0; i < 40; i++) begin
            bus_read(ADDR_DATA, c);
            if (c > prev) reloads++;
            if (c > maxv) maxv = c;
            prev = c;
        end
        check_true($sformatf("C6 recarga repetidamente (%0d recargas en 40 ciclos)", reloads), reloads >= 3);
        check_true($sformatf("C6 recarga el valor inicial 6 (maximo visto=%0d)", maxv), maxv >= 32'd5 && maxv <= 32'd6);
        bus_read(ADDR_CTRL, r);  check("C6 sigue corriendo con flag", r, RUN | AUTO | FAST | FLAG);

        bus_write(ADDR_CTRL, AUTO | FAST);               // RUN=0: detiene
        bus_read(ADDR_DATA, c1);
        repeat (4) @(negedge clk_i);
        bus_read(ADDR_DATA, c2);
        check("C6 RUN=0 detiene el auto-reload", c2, c1);

        // =====================================================================
        // Caso 7: modo lento (CLK_SEL=0): un decremento cada DIV ciclos
        // =====================================================================
        $display("\n--- Caso 7: modo lento ---");
        apply_reset();
        bus_write(ADDR_DATA, 32'd3);
        start_timer(RUN);                                // CLK_SEL=0, sin auto-reload
        prev = 32'd0;  decs = 0;  last_dec = -1;
        for (i = 0; i < 60 && timeout_o !== 1'b1; i++) begin
            bus_read(ADDR_DATA, c);
            if (c < prev) begin                          // decremento (la carga inicial sube, se ignora)
                decs++;
                if (last_dec >= 0)
                    check($sformatf("C7 separacion entre decrementos (valor %0d)", c), cyc - last_dec, DIV);
                last_dec = cyc;
            end
            prev = c;
        end
        wait_timeout(60);
        check("C7 numero de decrementos hasta cero", decs, 3);
        check_true("C7 timeout no es tan rapido como en modo rapido (>= 3*DIV)", elapsed >= 3 * DIV);
        check_true("C7 timeout llega poco despues de 3*DIV", elapsed <= 3 * DIV + 10);
        bus_read(ADDR_CTRL, r);  check("C7 RUN en 0, modo lento, flag=1", r, FLAG);

        // =====================================================================
        // Caso 8: reset síncrono durante una cuenta en curso
        // =====================================================================
        $display("\n--- Caso 8: reset durante la cuenta ---");
        apply_reset();
        bus_write(ADDR_DATA, 32'd50);
        start_timer(RUN | AUTO | FAST);
        repeat (8) @(negedge clk_i);
        bus_read(ADDR_DATA, c);
        check_true($sformatf("C8 cuenta en curso antes del reset (contador=%0d)", c), c > 32'd0 && c < 32'd50);

        apply_reset();
        bus_read(ADDR_CTRL, r);  check("C8 control en 0 tras reset", r, 32'h0);
        bus_read(ADDR_DATA, r);  check("C8 contador en 0 tras reset", r, 32'h0);
        check("C8 timeout_o=0 tras reset", {31'b0, timeout_o}, 32'h0);
        repeat (10) @(negedge clk_i);
        bus_read(ADDR_DATA, r);  check("C8 sigue detenido", r, 32'h0);
        check("C8 timeout_o sigue en 0", {31'b0, timeout_o}, 32'h0);

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
        #5000000;
        $display("ERROR: timeout del testbench");
        $finish;
    end

endmodule
