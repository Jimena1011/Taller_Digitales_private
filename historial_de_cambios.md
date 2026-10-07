# Historial de cambios y proceso de depuración

Este documento registra, en orden, los problemas que se encontraron al llevar el
proyecto (CPU RISC-V + periféricos + juego en ensamblador + aplicación de PC) a
la versión actual, cómo se diagnosticó cada uno, cómo se resolvió y cómo se
verificó. Sirve de base para escribir el historial de commits y la sección
«análisis de problemas encontrados y cómo se resolvieron» del informe.

**Convención de verificación.** *Simulación RTL* significa Vivado Simulator
(`xvlog`/`xelab`/`xsim`) sobre el top completo con el `.mem` real. *Implementación*
significa síntesis, place & route y bitstream en Vivado 2026.1 (modo batch).
*Placa* significa comprobado en la Basys 3. Lo que no dice «placa» está
verificado solo en simulación y falta confirmarlo con el hardware.

---

## 1. Estado final

| Elemento | Estado |
|---|---|
| Reloj de entrada | 100 MHz (único) |
| Reloj del VGA (`clk_pixel`) | 25 MHz, derivado con MMCM |
| Reloj del sistema (`clk_sys`: CPU, ROM, RAM, periféricos) | 33.33 MHz, derivado con MMCM |
| Timing (última implementación registrada) | WNS +6.599 ns, WHS +0.121 ns, 0 Critical Warnings |
| Recursos (primera síntesis completa) | ≈3.1k LUT (14.9 %), 1024 LUT como memoria, ≈1.3k registros, 0 BRAM |
| Programa (`asm/battleship.s`) | 607 palabras de 2048 de ROM |
| Protocolo UART | `0xA0` inicio de colocación, `0x06`/`0x15` respuesta, `0xA1` inicio de batalla, `0xB1` turno de J2, `0xB0 <idx> <res>`, `0xEE`, `0xE1`/`0xE2` |
| Colocación | Concurrente: J1 con botones y J2 por UART, sin esperarse |
| Sonidos del buzzer | 1 impacto, 2 fallo, 3 barco hundido, 4 colocación inválida de J1, 5 victoria; suenan para ambos jugadores |
| Sonidos de J2 en la PC | Colocación aceptada (100 ms) y rechazada (2 × 50 ms) |
| Pantalla VGA | Tableros, títulos «MI TABLERO»/«TABLERO RIVAL» y leyenda de colores |
| App de PC (`pc/battleship_gui.py`) | Mismos colores que la VGA, sin ejes, botones bajo cada tablero |

Las cifras de recursos corresponden a una corrida anterior a la leyenda de la VGA;
conviene volver a medirlas para el informe.

---

## 2. Cómo se verificó (infraestructura de pruebas)

Todas las pruebas se corrieron por línea de comandos, sin interfaz de Vivado.

- **Compilación y simulación:** `xvlog -sv`, `xelab -L unisims_ver`, `xsim -runall` sobre todas las fuentes de `sources_1/new`.
- **Implementación completa:** `vivado -mode batch -source impl.tcl` con `synth_design`, `opt_design`, `place_design`, `route_design`, `report_timing_summary`, `report_clocks`, `report_utilization`, `write_bitstream`.
- **Ensamblado:** `riscv64-unknown-elf-as`, `ld` y `objcopy -O verilog --verilog-data-width=4`. Cada vez se comprobó que el `.mem` coincidiera palabra por palabra con el desensamblado del `.elf`.
- **Testbenches de partida completa** (en una carpeta temporal de la sesión; ver sección 7): un jugador pulsa botones, el otro habla por UART real a 115200, y se comprueban todos los bytes.
- **Captura de un cuadro VGA real:** un testbench guarda los pixeles de salida de `vga_r/g/b` durante un cuadro, se convierte a imagen y se compara con la pantalla.
- **Pruebas de la interfaz de Python:** un puerto serie falso conectado a una FPGA simulada que replica el firmware, y capturas de pantalla de la ventana.

---

## 3. Cronología detallada

### 3.1 Cargar el `.mem` en Vivado

**Problema.** No quedaba claro cómo agregar el programa ensamblado a Vivado, y la
ruta del parámetro `ROM_INIT_FILE` era relativa (`"asm/battleship.mem"`).

**Causa.** Vivado no ejecuta desde la raíz del proyecto: la simulación corre desde
`proyect3_digitales.sim/.../xsim/` y la síntesis desde `.runs/synth_1/`. Con una
ruta relativa que no existe, `$readmemh` deja la ROM llena de NOP sin error
fuerte, solo un warning.

**Solución.**
- Solo el `.mem` entra al proyecto, como *Memory File*. Los `.s`, `.o` y `.elf` son pasos intermedios.
- `ROM_INIT_FILE` pasó a `"battleship.mem"` (Vivado busca los archivos del proyecto por nombre).
- Nuevo `tb_top_battleship.sv`: instancia el top **sin** sobrescribir la ROM y comprueba la primera, la segunda y la última palabra del programa, que el PC avance y que el LED quede en `001`.

**Por qué no servía el testbench existente.** `tb_top_module_basys3.sv` pasa
`ROM_INIT_FILE = ""` y escribe a mano un miniprograma en `u_program_rom.mem[0..18]`,
así que nunca prueba el `.mem`.

**Verificación.** Simulación: `PASS tb_top_battleship`. Síntesis: `$readmem data file
'battleship.mem' is read successfully`. Se probó también el caso negativo (sin
`.mem` en la carpeta) y el testbench da `FAIL` con `mem[0] = 00000013`.

**Detalle recurrente.** Cada vez que cambia el tamaño del programa hay que
actualizar `LAST_INDEX` en `tb_top_battleship.sv` (palabras − 1). Valores usados:
373 → 399 → 397 → 399 → 428 → 426 → 428 → **606** (final).

### 3.2 El top no compilaba en simulación

**Problema.** `xvlog` daba 9 errores `VRFC 10-1103: net type must be explicitly
specified` en las entradas del top.

**Causa.** El top usa `` `default_nettype none `` y las entradas estaban declaradas
`input logic`. Con `default_nettype none`, una entrada sin tipo de red explícito
es un error en el simulador.

**Solución.** `input logic` → `input wire` en las siete entradas de
`top_module_basys3.sv` (`clock`, `reset`, `btn_nav`, `btn_ok`, `btn_sel`,
`btn_rst`, `uart_rx`).

**Verificación.** Compilación y elaboración sin errores; `tb_cpu` y el top simulan.

### 3.3 `create_generated_clock` inválido en el XDC

**Problema.** Critical Warning `Vivado 12-4739: No valid object(s) found for
'-objects [get_pins u_pixel_clock/g_mmcm/u_pixel_bufg/O]'`.

**Causa.** Vivado nombra las celdas dentro de un bloque `generate` con punto
(`g_mmcm.u_pixel_bufg`), no con `/`. Además era redundante: Vivado ya deriva
automáticamente los relojes de las salidas del MMCM.

**Solución.** Se eliminó la línea. Más adelante se agregó un `set_clock_groups`
con los nombres correctos (sección 3.5).

### 3.4 El diseño no cumplía timing a 100 MHz

**Problema.** Tras implementar: WNS **−8.058 ns**, 10 748 de 13 471 endpoints
fallando (síntesis: −5.918 ns).

**Diagnóstico.** La ruta crítica (17.83 ns) es un solo `lw` recorriendo la CPU de
ciclo único completa. Desglose, tomado de `report_timing_summary`:

| Etapa | Tiempo |
|---|---|
| PC (clk→Q y fanout 170) | 1.79 ns |
| ROM de 2048×32 en LUT (LUT6 → MUXF7 → MUXF8 → LUT6) | 2.81 ns |
| Lectura del banco de registros | 2.60 ns |
| ALU y dirección de datos (incluye fanout 240 hacia la RAM) | 5.71 ns |
| RAM distribuida | 1.88 ns |
| Camino de vuelta (read mux, mux de resultado, escritura a registros) | 3.03 ns |
| **Total** | **17.83 ns** (20 % lógica, 80 % ruteo) |

**Alternativas.** Ajustes pequeños no reducen 17.8 ns a menos de 10 ns. Partir la
ruta exige multiciclo o pipeline, que se descartaron porque el instructivo pide
investigar el datapath de ciclo único. Quedó la opción de **derivar un reloj más
lento para la CPU**.

**Compatibilidad con el instructivo.** El texto pide «un único reloj de entrada de
100 MHz» y que de él «se derivarán, mediante PLL, las frecuencias necesarias»;
la arquitectura interna «queda abierta» (4.8). Derivar el reloj de la CPU con el
MMCM cumple eso, pero es una interpretación que conviene validar con el profesor.

### 3.5 Elección de la frecuencia del sistema

**Primer intento: 25 MHz.** `clk_sys = clk_pixel`. Funcionaba en timing, pero:
- La memoria de video dejaba de cruzar dominios de reloj (el instructivo pide un puerto por reloj y documentar la sincronización).
- Al calcular el divisor de la UART (`DIVISOR = (CLK_HZ + 8·BAUD)/(16·BAUD)`, entero) apareció que a 25 MHz el error de baudios es **−3.12 %**, demasiado para 115200.

| Reloj | Periodo | Margen sobre 17.8 ns | Divisor UART | Error de baudios |
|---|---|---|---|---|
| 100 MHz | 10 ns | −7.8 ns | 54 | +0.47 % |
| 50 MHz | 20 ns | +2.2 ns (justo) | 27 | +0.47 % |
| 40 MHz | 25 ns | +7.2 ns | 22 | −1.36 % |
| **33.33 MHz** | **30 ns** | **+12.2 ns** | **18** | **+0.47 %** |
| 25 MHz | 40 ns | +22.2 ns | 14 | −3.12 % |

**Solución adoptada: 33.33 MHz.** VCO = 100 MHz × 10 = 1000 MHz; `CLKOUT0/40` → 25 MHz
(VGA) y `CLKOUT1/30` → 33.33 MHz (sistema). Tiene divisor entero, error de baudios
igual que a 100 MHz y 12 ns de margen.

**Cambios.**
- `top_module_basys3.sv`: módulo `pixel_clock_gen` → `clock_gen` con dos salidas (`clk_pixel_o`, `clk_sys_o`); CPU, ROM, RAM y periféricos usan `clk_sys`; `CLK_HZ = 33_333_333`; modelo de simulación con dos relojes (`#20` y `#15`).
- `top_module_basys3.xdc`: `set_clock_groups -asynchronous` entre `CLKOUT0` y `CLKOUT1` (los únicos cruces son la memoria de video y el reset del VGA, que ya pasa por un sincronizador de 2 FF).
- Comentarios «100 MHz» y «PLL» actualizados en `vga.sv`, `vga_reset_sync.sv`, `data_ram.sv`, `local_inputs.sv` y `local_outputs.sv`.

**Verificación.** Frecuencias medidas en simulación: 33.333 MHz y 25.000 MHz.
Implementación: WNS **+5.945 ns**, TNS 0, WHS +0.122 ns, 0 Critical Warnings, y el
cruce `clk_sys` ↔ `clk_pixel` aparece como *Asynchronous / Ignored*. Estimación de
fmax ≈ 41 MHz (1 / (30 − 5.95) ns).

### 3.6 El LED nunca se podía escribir

**Problema.** El LED de estado no se encendía; el juego escribe `0x10138` al
iniciar la ronda.

**Causa.** `outputs_write_decoder` solo habilita escrituras con `addr_i == 2'b00`.
El decodificador de direcciones entrega `periph_addr = data_addr[3:2]`, y para el
LED (`0x...38`) eso vale `2'b10`. Los testbenches del periférico en aislamiento
pasaban porque inyectaban `addr_i = 00`; el error solo aparecía integrado.

**Solución.** En `address_decoder.sv`:
`periph_addr = cs_led ? {1'b0, data_addr[2]} : data_addr[3:2]`. Se corrigió en el
decodificador y no en el periférico, para no romper los testbenches unitarios.

**Verificación.** `led_state` pasó de `000` a `001` con el programa real;
`tb_cpu` sigue pasando.

### 3.7 `tb_top_module_basys3.sv` desactualizado

**Problema.** Daba timeout: el byte `A5` nunca salía por `uart_tx`.

**Causa.** El testbench escribía a `0x10004` y `0x10000`, direcciones de un mapa
anterior; la UART está en `0x10044` (datos TX) y `0x10040` (control).

**Solución.** Offsets `4` → `16'h44` y `0` → `16'h40` en las dos instrucciones `sw`.
**Verificación.** `PASS tb_top_module_basys3: CPU, ROM, RAM, LED, UART TX/RX y VGA`.

### 3.8 Entradas flotantes: los botones no respondían en la placa

**Problema.** La pantalla se dibujaba bien pero el cursor no se movía.

**Diagnóstico.** En simulación los cuatro botones movían el cursor correctamente
(`0→1→9→8→0`), así que el problema era de la placa. `btn_sel` (JA2) y `btn_rst`
(JA3) eran entradas sin pull-down: sin botón conectado flotan, el programa lee
`BTN_RST` como presionado y reinicia la ronda sin parar (`wait_button` nunca
termina).

**Solución.** `PULLDOWN true` en esos dos pines del XDC.
**Verificación.** Placa: los botones mueven el cursor y se colocan los barcos.

### 3.9 Errores del firmware (`asm/battleship.s`)

El firmware se revisó contra el instructivo y contra el hardware. La versión
original con colocación secuencial se reemplazó por la de la compañera
(colocación concurrente, cumple 4.3.1 punto 4); sobre ella se corrigió lo
siguiente.

**a) Generación del `.mem`.** `objcopy -O verilog` sin opción escribe bytes; el
`.mem` debe llevar una palabra de 32 bits por entrada: añadir
`--verilog-data-width=4`. El README de `asm/` no lo decía; se corrigió.

**b) Se colocaban 4 barcos (largos 4, 3, 2 y 1).** Los lazos terminaban con
`s1 >= 1` y `s1 != 0`. La victoria se declaraba a los 9 impactos (4+3+2). Corregido
en la versión original; la versión concurrente usa contadores 0..2 y no lo tiene.

**c) El cursor de J1 saltaba.** El disparo de J2 se guardaba en `s0`, que es el
cursor del Jugador 1. Ahora usa `s4` (versión secuencial) y `s5` (versión
concurrente). Se detectó porque la simulación mostraba cursores inesperados tras el
primer disparo de J2.

**d) Registros corrompidos en la colocación (el error más grave).**
`valid_placement` modificaba `t3`, `t4`, `t5` y `a1`, y quien la llamaba los
reutilizaba después para `place_ship`. Resultado: J1 llenaba **las 64 casillas** de
barco tras el primer OK, y J2 aceptaba traslapes (`06` en vez de `15`). Se detectó
con la simulación de partida completa (`total barco = 64`). **Solución:**
`valid_placement` ahora usa `t6` como copia del índice y conserva `a1`, `a2`, `a3`;
los llamadores ya no recopian argumentos.

**e) `BTN_RST` mantenido enviaba cientos de `0xA0`.** `new_round` se reentraba en cada
vuelta mientras el botón seguía presionado. Ahora espera a que se suelte.

**f) Disparo fantasma al empezar la batalla.** Con colocación concurrente, si J2
termina antes que J1, el OK que confirma el último barco de J1 sigue presionado al
entrar en batalla y `wait_button` lo leía como un disparo a la casilla 0. Se detectó
porque la celda 0 del tablero de J2 ya aparecía como impacto (`3`) antes de que
nadie disparara. Ahora, tras enviar `0xA1`, el programa espera a que se suelten
todos los botones.

**g) Barco hundido.** No existía: los tableros guardaban solo «barco» (2). Cada
casilla ahora guarda el estado en los bits `[2:0]` (0 agua, 2 barco, 3 impacto,
4 fallo) y el identificador del barco (1..3) en los bits `[9:8]`. `place_ship`
recibe el id en `a4`; `shoot` devuelve en `a1` si el impacto hundió el barco
(ya no queda ninguna casilla con estado 2 y ese id). `render_board` enmascara con
`andi t2, t2, 7` para no dibujar el id.

**h) Sonidos para ambos jugadores.** Los disparos de J2 no sonaban. Ahora impacto
(1), fallo (2) y hundido (3) suenan igual para J1 y J2; la victoria (5) interrumpe
el sonido del último impacto.

**i) Sonido de colocación inválida de J2.** Primero se envió al buzzer; después se
quitó (la fase de colocación es simultánea y el buzzer queda cerca de J1) y pasó a
la PC (sección 3.11).

**j) Retraso al mostrar el acierto/fallo.** Tras el disparo de J1, el tablero no se
redibujaba hasta volver al turno de J1 (después de que J2 respondiera). Se agregó
`draw_boards` inmediatamente después de cada disparo, también cuando es el disparo
ganador.

**k) Títulos y leyenda en la VGA.** Rutinas `put_tile` y `draw_legend` (41 casillas
de video, macros `TILE` y `CH`). Sin cambios de hardware: la ROM de glifos ya tiene
0-9, A-H, I, J, L, M, N, O, P, R, S, T, U, V y el guion (no hay K, Q, W, X, Y, Z).
Contenido: «MI / TABLERO» y «TABLERO / RIVAL» sobre cada tablero (filas 1-2) y la
leyenda rojo = ACIERTO, blanco = FALLO, gris = BARCO (filas 12-14). Los títulos van
en dos líneas porque «TABLERO RIVAL» mide 13 casillas.

**Verificación (simulación RTL, partida completa).** Colocación de J2 antes que J1,
colocación intercalada, rechazos `15` por fuera de tablero y traslape, nueve
impactos, `EE` por repetido, `E1` y reinicio con un solo `A0`.
Secuencia de sonidos registrada contra la esperada:
`1,1,1,1,1,1,3,1,2,3,2,1,2,1,2,3,2,1,2,3,5` (**SONIDOS OK**). El resultado de cada
disparo se verificó en la memoria de video de inmediato (`0x103` y `0x003`). Un
cuadro VGA capturado confirma títulos y leyenda.

### 3.10 Evolución del tamaño del programa

369 (original) → 374 → 400 (versión concurrente) → 398 → 400 → 429 → 427 → 429 →
**607** (con leyenda de la VGA).

### 3.11 Aplicación de Python (Jugador 2)

La aplicación final es la GUI de la compañera (`pc/battleship_gui.py`). Antes se
probó una implementación propia con tableros y modo demo, que sirvió para
validar el protocolo contra una FPGA simulada. Cambios sobre la GUI de la compañera:

- **Reinicio de ronda.** Al llegar `0xA0` por segunda vez (`BTN_RST` o `SW0`) la app conservaba los barcos y marcas de la ronda anterior, con `game_over = True`, y no dejaba colocar otra vez. `_start_new_round()` descarta el estado anterior. Se probaron dos rondas completas.
- **Sonidos de J2 en la PC.** Colocación aceptada: un pitido de 100 ms. Rechazada: dos pitidos de 50 ms con 50 ms de pausa (mismos patrones que el buzzer da a J1). Usa `winsound` (solo Windows; en otro sistema usa `bell`).
- **Misma interfaz que la VGA.** Paleta leída de `tile_renderer.sv`: mar `#3377DD`, barco `#889999`, acierto `#DD3322`, fallo `#EEEEEE`, cuadrícula `#222233`, selección `#FFCC44`. Barcos de un solo color, aciertos y fallos como casilla rellena, marco amarillo para la selección y leyenda de colores.
- **Sin ejes ni etiquetas de celda.** Se eliminaron las letras A-H y los números, y los textos «Celda: G6 (indice 46)». Los mensajes de estado ya no incluyen el número de casilla. El registro de comunicación conserva los índices para depurar.
- **Botones junto a cada tablero.** «Rotar» y «Enviar barco» bajo «Mi tablero»; «Enviar disparo» bajo «Tablero rival».
- **Corrección de un estado roto.** Una línea de configuración comentada dejaba una constante sin definir y la ventana fallaba al dibujar; se resolvió al eliminar los ejes por completo.

**Verificación.** Puerto serie falso + FPGA simulada que replica el firmware:
rechazo con reintento, colocación, batalla, fin y segunda ronda completa; capturas
de la ventana. Los pitidos se comprobaron con un `winsound` falso (50 ms, pausa de
50 ms, 50 ms, y 100 ms por barco aceptado).

---

## 4. Tabla de commits sugerida

Un commit por cambio lógico, en este orden. Los mensajes siguen el formato
`tipo(ámbito): resumen`.

| # | Mensaje sugerido | Archivos | Sección |
|---|---|---|---|
| 1 | `fix(top): declarar las entradas como wire para compilar con default_nettype none` | `sources_1/new/top_module_basys3.sv` | 3.2 |
| 2 | `fix(xdc): eliminar create_generated_clock con ruta inválida` | `constrs_1/new/top_module_basys3.xdc` | 3.3 |
| 3 | `feat(clk): derivar clk_pixel (25 MHz) y clk_sys (33.33 MHz) con el MMCM para cumplir timing` | `top_module_basys3.sv`, `top_module_basys3.xdc` | 3.4, 3.5 |
| 4 | `docs(rtl): actualizar los comentarios de frecuencia del sistema` | `vga.sv`, `vga_reset_sync.sv`, `data_ram.sv`, `local_inputs.sv`, `local_outputs.sv` | 3.5 |
| 5 | `fix(bus): direccionar el registro del LED relativo a su base` | `sources_1/new/address_decoder.sv` | 3.6 |
| 6 | `fix(xdc): pull-down interno en btn_sel y btn_rst` | `top_module_basys3.xdc` | 3.8 |
| 7 | `test(top): corregir las direcciones de la UART en tb_top_module_basys3` | `sim_1/new/tb_top_module_basys3.sv` | 3.7 |
| 8 | `test(top): comprobar la carga de battleship.mem y el arranque del programa` | `sim_1/new/tb_top_battleship.sv` (nuevo) | 3.1 |
| 9 | `fix(asm): conservar a1-a3 en valid_placement` | `asm/battleship.s` | 3.9 d |
| 10 | `fix(asm): guardar el disparo de J2 en s5 (no en el cursor s0)` | `asm/battleship.s` | 3.9 c |
| 11 | `fix(asm): esperar a soltar BTN_RST y los botones antes de la batalla` | `asm/battleship.s` | 3.9 e, f |
| 12 | `feat(asm): detectar barco hundido y sonar para ambos jugadores` | `asm/battleship.s` | 3.9 g, h |
| 13 | `fix(asm): redibujar el tablero justo después de cada disparo` | `asm/battleship.s` | 3.9 j |
| 14 | `feat(asm): títulos de los tableros y leyenda de colores en la VGA` | `asm/battleship.s` | 3.9 k |
| 15 | `build(asm): regenerar el .mem con --verilog-data-width=4` | `asm/battleship.mem`, `asm/README.md` | 3.9 a |
| 16 | `fix(pc): reiniciar el estado de la partida al recibir 0xA0` | `pc/battleship_gui.py` | 3.11 |
| 17 | `feat(pc): sonidos de colocación aceptada y rechazada del Jugador 2` | `pc/battleship_gui.py` | 3.11 |
| 18 | `style(pc): usar la paleta de la VGA, barcos de un color y marco de selección` | `pc/battleship_gui.py` | 3.11 |
| 19 | `refactor(pc): quitar ejes y etiquetas; botones bajo cada tablero` | `pc/battleship_gui.py` | 3.11 |
| 20 | `docs: historial de cambios y proceso de depuración` | `docs/historial_de_cambios.md` | — |

**Notas para armar los commits.**
- Los estados intermedios exactos de cada archivo no se guardaron. Para separar los commits 9 a 14 en un mismo `battleship.s` hay que aplicar los cambios por partes (con `git add -p`) a partir de la versión que tenga el historial del repositorio de la compañera.
- El commit 15 se hace al final de los cambios de firmware; el `.mem` debe corresponder siempre al `.s` del mismo commit.
- Si se prefiere menos commits, se pueden agrupar por tema: *reloj y timing* (1-4), *hardware* (5-6), *pruebas* (7-8), *firmware* (9-15), *PC* (16-19).

---

## 5. Pendiente frente al instructivo

Estos puntos cambian el protocolo y hay que acordarlos entre el firmware y la app:

| Requisito | Estado |
|---|---|
| Aviso de barco hundido por UART (4.5.3) | Falta: el firmware ya lo detecta y suena, pero no lo envía |
| Motivo del rechazo de una colocación (traslape o fuera de tablero) | Falta: solo existe `0x15` |
| Cambio de turno hacia J1 como mensaje | Falta: solo se envía `0xB1` (turno de J2) |
| Resumen final (disparos totales, barcos hundidos) | Falta: solo se envía el ganador |
| El Jugador 2 envía identificador del barco y casilla `(fila, columna)` | Se envía `<indice> <orientacion>` |
| Descartar bytes inválidos sin afectar la partida | Parcial: un byte suelto durante la colocación hace esperar el segundo byte |
| Simulación post-implementación temporizada | Pendiente |
| Documentación (`planteamiento.md`) | Desactualizada: figura `clk_sys` de 100 MHz, tick de 1 ms como 100 000 ciclos, y `0xA1` con otro significado |

Pendiente de confirmar **en la placa**: títulos y leyenda de la VGA, redibujado
inmediato tras cada disparo, sonidos de J2 en la PC y la GUI con el nuevo diseño.

---

## 6. Comandos útiles

```powershell
# Generar el .mem a partir del ensamblador (desde la raíz del proyecto)
riscv64-unknown-elf-as -march=rv32i -mabi=ilp32 -o asm/battleship.o asm/battleship.s
riscv64-unknown-elf-ld -m elf32lriscv -Ttext=0 -e _start -o asm/battleship.elf asm/battleship.o
riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=4 asm/battleship.elf asm/battleship.mem

# App de PC
cd pc
python -m pip install -r requirements.txt
python battleship_gui.py
```

En Vivado, tras cambiar el `.s`: regenerar el `.mem`, cerrar la simulación si está
abierta, *Run Synthesis* (buscar `$readmem ... read successfully` en el log),
*Run Implementation* y *Generate Bitstream*. Vivado no regenera el `.mem` por sí
solo.

---

## 7. Evidencia de simulación

Los testbenches de partida completa y los arneses de la interfaz se escribieron en
una carpeta temporal de la sesión de trabajo y **no forman parte del proyecto**:

| Prueba | Qué comprueba |
|---|---|
| Partida con J2 coloca antes que J1 | Colocación concurrente, rechazos `15`, batalla completa, `E1`, `A0` |
| Partida con colocación intercalada | `A1` solo cuando ambos terminan; ningún disparo fantasma |
| Secuencia de sonidos | Cada escritura al buzzer en una partida completa |
| Redibujado inmediato | Contenido de la memoria de video tras cada disparo |
| Captura de un cuadro VGA | Imagen de la salida real con títulos y leyenda |
| Arnés de la GUI | Dos rondas completas con puerto serie falso |

Si se quiere presentar como «pruebas de autochequeo» (rúbrica de simulación
autoverificable), conviene copiarlos a `proyect3_digitales.srcs/sim_1/new/` y
documentar su criterio de pase y fallo.
