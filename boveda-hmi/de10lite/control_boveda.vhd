library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity control_boveda is
    Port (
        CLOCK_50        : in  STD_LOGIC; -- PIN_P11
        reset_n         : in  STD_LOGIC; -- PIN_B8 (KEY0)
        -- Comunicación Serial (CP2102 <-> Tablet HMI)
        uart_rx         : in  STD_LOGIC; -- PIN_V10 (JP1 Pin 1)
        uart_tx         : out STD_LOGIC; -- PIN_W10 (JP1 Pin 2)
        -- Interfaz directa con ESP32 (AS608 - 3.3V LVTTL)
        hab_huella      : out STD_LOGIC; -- PIN_W12  -> ESP32 GPIO 18
        huella_ok       : in  STD_LOGIC; -- PIN_AB12 <- ESP32 GPIO 19
        huella_err      : in  STD_LOGIC; -- PIN_AB11 <- ESP32 GPIO 21
        huella_cruz     : in  STD_LOGIC; -- PIN_AA12 <- ESP32 GPIO 25 (Error cruzado)
        user_id         : out STD_LOGIC_VECTOR(1 downto 0); -- [0]=PIN_AB10 (GPIO 22), [1]=PIN_AA11 (GPIO 23)
        -- Sensor de Puerta (Microswitch: 1 = Abierta, 0 = Cerrada)
        sensor_puerta   : in  STD_LOGIC; -- PIN_V9  (JP1 Pin 3)
        -- Actuadores de la Bóveda
        cerrojo_digital : out STD_LOGIC; -- PIN_W9  (Opcional)
        servo_pwm       : out STD_LOGIC; -- PIN_AA15 (PWM 50Hz para SG90)
        buzzer          : out STD_LOGIC; -- PIN_V8  (JP1 Pin 5: Buzzer Pasivo)
        -- LEDs de Progreso (L1, L2, L3)
        leds_fase       : out STD_LOGIC_VECTOR(2 downto 0); -- PIN_W8, PIN_V7, PIN_W7
        -- LED RGB Estado Global (RG)
        rgb_r           : out STD_LOGIC; -- PIN_W6  (JP1 Pin 9)
        rgb_g           : out STD_LOGIC; -- PIN_V5  (JP1 Pin 10)
        rgb_b           : out STD_LOGIC; -- PIN_W5  (JP1 Pin 13)
        -- Depuración visual en la misma DE10-Lite
        ledr_estado     : out STD_LOGIC_VECTOR(4 downto 0)  -- LEDR[4..0]
    );
end control_boveda;

architecture Behavioral of control_boveda is

    component uart_transceiver is
        Generic (
            CLK_FREQ  : integer := 50_000_000;
            BAUD_RATE : integer := 9600
        );
        Port (
            clk       : in  STD_LOGIC;
            reset_n   : in  STD_LOGIC;
            rx_serial : in  STD_LOGIC;
            rx_data   : out STD_LOGIC_VECTOR(7 downto 0);
            rx_valid  : out STD_LOGIC;
            tx_start  : in  STD_LOGIC;
            tx_data   : in  STD_LOGIC_VECTOR(7 downto 0);
            tx_serial : out STD_LOGIC;
            tx_busy   : out STD_LOGIC
        );
    end component;

    type estado_t is (
        S0_REPOSO_FACIAL,
        S1_VOZ,
        S2_HUELLA,
        S3_BOVEDA_ABIERTA,
        S4_BLOQUEO_TOTAL
    );
    signal estado_actual : estado_t := S0_REPOSO_FACIAL;
    signal usuario_reg   : STD_LOGIC_VECTOR(1 downto 0) := "00"; -- 01=Santiago, 10=David, 11=Abner

    -- Señales UART
    signal rx_byte  : STD_LOGIC_VECTOR(7 downto 0);
    signal rx_done  : STD_LOGIC;
    signal tx_trig  : STD_LOGIC := '0';
    signal tx_byte  : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal tx_ocup  : STD_LOGIC;

    -- Sincronizadores y detección de flanco de subida para señales de la ESP32
    signal h_ok_sync    : STD_LOGIC_VECTOR(2 downto 0) := "000";
    signal h_err_sync   : STD_LOGIC_VECTOR(2 downto 0) := "000";
    signal h_cruz_sync  : STD_LOGIC_VECTOR(2 downto 0) := "000";
    signal h_ok_pulse   : STD_LOGIC := '0';
    signal h_err_pulse  : STD_LOGIC := '0';
    signal h_cruz_pulse : STD_LOGIC := '0';

    -- Constantes de tiempo @ 50 MHz
    constant UN_SEGUNDO      : integer := 50_000_000;
    constant DEBOUNCE_LIMIT  : integer := 1_000_000; -- 20 ms anti-rebote microswitch
    constant TIEMPO_MAX_SEG  : integer := 60;
    constant GRACIA_PUERTA_S : integer := 3;

    -- Contadores y registros de control
    signal clk_1s_cnt    : integer range 0 to UN_SEGUNDO - 1 := 0;
    signal pulso_1s      : STD_LOGIC := '0';
    signal seg_timer     : integer range 0 to 63 := 0;
    signal fallos_cnt    : integer range 0 to 3 := 0;
    signal alerta_error  : STD_LOGIC := '0';
    signal alerta_timer  : integer range 0 to UN_SEGUNDO := 0;

    -- Anti-rebote del sensor de puerta (P)
    signal p_sync        : STD_LOGIC_VECTOR(1 downto 0) := "00";
    signal p_clean       : STD_LOGIC := '0';
    signal p_deb_cnt     : integer range 0 to DEBOUNCE_LIMIT := 0;

    -- Control de Buzzer
    signal bz_mode       : STD_LOGIC_VECTOR(1 downto 0) := "00";
    signal bz_dur_cnt    : integer range 0 to UN_SEGUNDO := 0;
    signal tone_cnt      : integer range 0 to 50_000 := 0;
    signal tone_wave     : STD_LOGIC := '0';

    -- Control PWM para Servomotor SG90 (50 Hz -> periodo 20 ms = 1,000,000 ciclos)
    constant PWM_PERIOD  : integer := 1_000_000;
    constant SERVO_0DEG  : integer := 114_850; -- Posición fija (170° en escala Servo.h = 2.297 ms)
    constant SERVO_90DEG : integer := 73_600;  -- Posición abierta (-80° = 90° en escala Servo.h = 1.472 ms)
    signal pwm_cnt       : integer range 0 to PWM_PERIOD - 1 := 0;
    signal cerrojo_int   : STD_LOGIC := '0';

begin

    U_UART: uart_transceiver
        generic map (
            CLK_FREQ  => 50_000_000,
            BAUD_RATE => 9600
        )
        port map (
            clk       => CLOCK_50,
            reset_n   => reset_n,
            rx_serial => uart_rx,
            rx_data   => rx_byte,
            rx_valid  => rx_done,
            tx_start  => tx_trig,
            tx_data   => tx_byte,
            tx_serial => uart_tx,
            tx_busy   => tx_ocup
        );

    -- 1. Generador de pulso exacto de 1 segundo
    process(CLOCK_50, reset_n)
    begin
        if reset_n = '0' then
            clk_1s_cnt <= 0;
            pulso_1s   <= '0';
        elsif rising_edge(CLOCK_50) then
            if clk_1s_cnt = UN_SEGUNDO - 1 then
                clk_1s_cnt <= 0;
                pulso_1s   <= '1';
            else
                clk_1s_cnt <= clk_1s_cnt + 1;
                pulso_1s   <= '0';
            end if;
        end if;
    end process;

    -- 2. Filtro anti-rebote (20 ms) para el microswitch de puerta (P)
    process(CLOCK_50, reset_n)
    begin
        if reset_n = '0' then
            p_sync    <= "00";
            p_clean   <= '0';
            p_deb_cnt <= 0;
        elsif rising_edge(CLOCK_50) then
            p_sync <= p_sync(0) & sensor_puerta;
            if p_sync(1) /= p_clean then
                if p_deb_cnt < DEBOUNCE_LIMIT then
                    p_deb_cnt <= p_deb_cnt + 1;
                else
                    p_clean   <= p_sync(1);
                    p_deb_cnt <= 0;
                end if;
            else
                p_deb_cnt <= 0;
            end if;
        end if;
    end process;

    -- 3. Máquina de Estados Finitos Principal (FSM: S0 a S4)
    process(CLOCK_50, reset_n)
    begin
        if reset_n = '0' then
            estado_actual <= S0_REPOSO_FACIAL;
            usuario_reg   <= "00";
            seg_timer     <= 0;
            fallos_cnt    <= 0;
            bz_mode       <= "00";
            bz_dur_cnt    <= 0;
            alerta_error  <= '0';
            alerta_timer  <= 0;
            tx_trig       <= '0';
            tx_byte       <= (others => '0');
            h_ok_sync     <= "000";
            h_err_sync    <= "000";
            h_cruz_sync   <= "000";
            h_ok_pulse    <= '0';
            h_err_pulse   <= '0';
            h_cruz_pulse  <= '0';

        elsif rising_edge(CLOCK_50) then
            tx_trig <= '0';

            -- Sincronización y flanco de subida de ESP32
            h_ok_sync   <= h_ok_sync(1 downto 0)   & huella_ok;
            h_err_sync  <= h_err_sync(1 downto 0)  & huella_err;
            h_cruz_sync <= h_cruz_sync(1 downto 0) & huella_cruz;

            if h_ok_sync(2 downto 1) = "01"   then h_ok_pulse   <= '1'; else h_ok_pulse   <= '0'; end if;
            if h_err_sync(2 downto 1) = "01"  then h_err_pulse  <= '1'; else h_err_pulse  <= '0'; end if;
            if h_cruz_sync(2 downto 1) = "01" then h_cruz_pulse <= '1'; else h_cruz_pulse <= '0'; end if;

            if bz_dur_cnt > 0 then
                bz_dur_cnt <= bz_dur_cnt - 1;
                if bz_dur_cnt = 1 then
                    bz_mode <= "00";
                end if;
            end if;

            if alerta_timer > 0 then
                alerta_timer <= alerta_timer - 1;
                if alerta_timer = 1 then
                    alerta_error <= '0';
                end if;
            end if;

            -- Reinicio Manual ('R' = 0x52)
            if rx_done = '1' and rx_byte = x"52" then
                estado_actual <= S0_REPOSO_FACIAL;
                usuario_reg   <= "00";
                seg_timer     <= 0;
                fallos_cnt    <= 0;
                alerta_error  <= '0';
                bz_mode       <= "00";
                bz_dur_cnt    <= 0;

            else
                case estado_actual is

                    -- =========================================================
                    -- S0: REPOSO INICIAL / RECONOCIMIENTO FACIAL
                    -- =========================================================
                    when S0_REPOSO_FACIAL =>
                        seg_timer <= 0;

                        if rx_done = '1' then
                            case rx_byte is
                                when x"31" => -- '1': Santiago -> S1
                                    usuario_reg   <= "01";
                                    estado_actual <= S1_VOZ;
                                    seg_timer     <= 0;
                                    alerta_error  <= '0';
                                    bz_mode       <= "01";
                                    bz_dur_cnt    <= 12_500_000;

                                when x"32" => -- '2': David -> S1
                                    usuario_reg   <= "10";
                                    estado_actual <= S1_VOZ;
                                    seg_timer     <= 0;
                                    alerta_error  <= '0';
                                    bz_mode       <= "01";
                                    bz_dur_cnt    <= 12_500_000;

                                when x"33" => -- '3': Abner -> S1
                                    usuario_reg   <= "11";
                                    estado_actual <= S1_VOZ;
                                    seg_timer     <= 0;
                                    alerta_error  <= '0';
                                    bz_mode       <= "01";
                                    bz_dur_cnt    <= 12_500_000;

                                when x"45" => -- 'E'
                                    if fallos_cnt >= 2 then
                                        estado_actual <= S4_BLOQUEO_TOTAL;
                                        usuario_reg   <= "00";
                                        seg_timer     <= 0;
                                        fallos_cnt    <= 0;
                                        alerta_error  <= '0';
                                        bz_mode       <= "11";
                                        bz_dur_cnt    <= 0;
                                    else
                                        fallos_cnt    <= fallos_cnt + 1;
                                        alerta_error  <= '1';
                                        alerta_timer  <= 50_000_000;
                                        bz_mode       <= "10";
                                        bz_dur_cnt    <= 25_000_000;
                                    end if;

                                when x"42" => -- 'B'
                                    estado_actual <= S4_BLOQUEO_TOTAL;
                                    usuario_reg   <= "00";
                                    seg_timer     <= 0;
                                    fallos_cnt    <= 0;
                                    alerta_error  <= '0';
                                    bz_mode       <= "11";
                                    bz_dur_cnt    <= 0;

                                when others =>
                                    null;
                            end case;
                        end if;

                    -- =========================================================
                    -- S1: RECONOCIMIENTO DE VOZ (Sin cambios)
                    -- =========================================================
                    when S1_VOZ =>
                        if pulso_1s = '1' then
                            if seg_timer >= TIEMPO_MAX_SEG - 1 then
                                estado_actual <= S0_REPOSO_FACIAL;
                                usuario_reg   <= "00";
                                seg_timer     <= 0;
                                fallos_cnt    <= 0;
                                alerta_error  <= '0';
                                bz_mode       <= "00";
                            else
                                seg_timer <= seg_timer + 1;
                            end if;
                        end if;

                        if rx_done = '1' then
                            case rx_byte is
                                when x"56" => -- 'V' -> S2
                                    estado_actual <= S2_HUELLA;
                                    seg_timer     <= 0;
                                    alerta_error  <= '0';
                                    bz_mode       <= "01";
                                    bz_dur_cnt    <= 12_500_000;

                                when x"45" => -- 'E'
                                    if fallos_cnt >= 2 then
                                        estado_actual <= S4_BLOQUEO_TOTAL;
                                        usuario_reg   <= "00";
                                        seg_timer     <= 0;
                                        fallos_cnt    <= 0;
                                        alerta_error  <= '0';
                                        bz_mode       <= "11";
                                        bz_dur_cnt    <= 0;
                                    else
                                        fallos_cnt    <= fallos_cnt + 1;
                                        alerta_error  <= '1';
                                        alerta_timer  <= 50_000_000;
                                        bz_mode       <= "10";
                                        bz_dur_cnt    <= 25_000_000;
                                    end if;

                                when x"42" => -- 'B'
                                    estado_actual <= S4_BLOQUEO_TOTAL;
                                    usuario_reg   <= "00";
                                    seg_timer     <= 0;
                                    fallos_cnt    <= 0;
                                    alerta_error  <= '0';
                                    bz_mode       <= "11";
                                    bz_dur_cnt    <= 0;

                                when x"54" => -- 'T'
                                    estado_actual <= S0_REPOSO_FACIAL;
                                    usuario_reg   <= "00";
                                    seg_timer     <= 0;
                                    fallos_cnt    <= 0;

                                when others =>
                                    null;
                            end case;
                        end if;

                    -- =========================================================
                    -- S2: HUELLA DIGITAL AS608 (OK, ERROR GENERAL, ERROR CRUZADO)
                    -- =========================================================
                    when S2_HUELLA =>
                        if pulso_1s = '1' then
                            if seg_timer >= TIEMPO_MAX_SEG - 1 then
                                estado_actual <= S0_REPOSO_FACIAL;
                                usuario_reg   <= "00";
                                seg_timer     <= 0;
                                fallos_cnt    <= 0;
                                alerta_error  <= '0';
                                bz_mode       <= "00";
                            else
                                seg_timer <= seg_timer + 1;
                            end if;
                        end if;

                        -- 1) Huella válida correspondiente al usuario (PIN_AB12) o simulación ('H')
                        if h_ok_pulse = '1' or (rx_done = '1' and rx_byte = x"48") then
                            estado_actual <= S3_BOVEDA_ABIERTA;
                            seg_timer     <= 0;
                            fallos_cnt    <= 0;
                            alerta_error  <= '0';
                            bz_mode       <= "01";
                            bz_dur_cnt    <= 12_500_000;
                            if h_ok_pulse = '1' and tx_ocup = '0' then
                                tx_byte <= x"48"; -- 'H'
                                tx_trig <= '1';
                            end if;

                        -- 2) Error de Autenticación Cruzada desde ESP32 (PIN_AA12) -> envía 'C'
                        elsif h_cruz_pulse = '1' then
                            if fallos_cnt >= 2 then
                                estado_actual <= S4_BLOQUEO_TOTAL;
                                usuario_reg   <= "00";
                                seg_timer     <= 0;
                                fallos_cnt    <= 0;
                                alerta_error  <= '0';
                                bz_mode       <= "11";
                                bz_dur_cnt    <= 0;
                                if tx_ocup = '0' then
                                    tx_byte <= x"42"; -- 'B' (Bloqueo)
                                    tx_trig <= '1';
                                end if;
                            else
                                fallos_cnt    <= fallos_cnt + 1;
                                alerta_error  <= '1';
                                alerta_timer  <= 50_000_000;
                                bz_mode       <= "10";
                                bz_dur_cnt    <= 25_000_000;
                                if tx_ocup = '0' then
                                    tx_byte <= x"43"; -- 'C' (Error cruzado en S2)
                                    tx_trig <= '1';
                                end if;
                            end if;

                        -- 3) Error general de huella desde ESP32 (PIN_AB11) o UART ('E')
                        elsif h_err_pulse = '1' or (rx_done = '1' and rx_byte = x"45") then
                            if fallos_cnt >= 2 then
                                estado_actual <= S4_BLOQUEO_TOTAL;
                                usuario_reg   <= "00";
                                seg_timer     <= 0;
                                fallos_cnt    <= 0;
                                alerta_error  <= '0';
                                bz_mode       <= "11";
                                bz_dur_cnt    <= 0;
                                if h_err_pulse = '1' and tx_ocup = '0' then
                                    tx_byte <= x"42"; -- 'B'
                                    tx_trig <= '1';
                                end if;
                            else
                                fallos_cnt    <= fallos_cnt + 1;
                                alerta_error  <= '1';
                                alerta_timer  <= 50_000_000;
                                bz_mode       <= "10";
                                bz_dur_cnt    <= 25_000_000;
                                if h_err_pulse = '1' and tx_ocup = '0' then
                                    tx_byte <= x"45"; -- 'E'
                                    tx_trig <= '1';
                                end if;
                            end if;

                        elsif rx_done = '1' and rx_byte = x"42" then -- 'B'
                            estado_actual <= S4_BLOQUEO_TOTAL;
                            usuario_reg   <= "00";
                            seg_timer     <= 0;
                            fallos_cnt    <= 0;
                            alerta_error  <= '0';
                            bz_mode       <= "11";
                            bz_dur_cnt    <= 0;

                        elsif rx_done = '1' and rx_byte = x"54" then -- 'T'
                            estado_actual <= S0_REPOSO_FACIAL;
                            usuario_reg   <= "00";
                            seg_timer     <= 0;
                            fallos_cnt    <= 0;
                        end if;

                    -- =========================================================
                    -- S3: BÓVEDA ABIERTA (Servo a 90°, espera cierre P=0)
                    -- =========================================================
                    when S3_BOVEDA_ABIERTA =>
                        if pulso_1s = '1' and seg_timer < GRACIA_PUERTA_S then
                            seg_timer <= seg_timer + 1;
                        end if;

                        if seg_timer >= GRACIA_PUERTA_S and p_clean = '0' then
                            estado_actual <= S0_REPOSO_FACIAL;
                            usuario_reg   <= "00";
                            seg_timer     <= 0;
                            bz_mode       <= "01";
                            bz_dur_cnt    <= 12_500_000;
                            if tx_ocup = '0' then
                                tx_byte <= x"43"; -- 'C' (Bóveda cerrada en S3)
                                tx_trig <= '1';
                            end if;
                        end if;

                    -- =========================================================
                    -- S4: BLOQUEO TOTAL (60 segundos)
                    -- =========================================================
                    when S4_BLOQUEO_TOTAL =>
                        bz_mode <= "11";
                        if pulso_1s = '1' then
                            if seg_timer >= TIEMPO_MAX_SEG - 1 then
                                estado_actual <= S0_REPOSO_FACIAL;
                                usuario_reg   <= "00";
                                seg_timer     <= 0;
                                fallos_cnt    <= 0;
                                bz_mode       <= "00";
                            else
                                seg_timer <= seg_timer + 1;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

    -- 4. Generador de frecuencias de audio para Buzzer Pasivo
    process(CLOCK_50)
        variable half_period : integer;
    begin
        if rising_edge(CLOCK_50) then
            case bz_mode is
                when "01" => half_period := 12_500;
                when "10" => half_period := 41_666;
                when "11" =>
                    if clk_1s_cnt < 25_000_000 then half_period := 25_000;
                    else half_period := 12_500;
                    end if;
                when others => half_period := 0;
            end case;

            if half_period = 0 then
                tone_cnt  <= 0;
                tone_wave <= '0';
            else
                if tone_cnt >= half_period - 1 then
                    tone_cnt  <= 0;
                    tone_wave <= not tone_wave;
                else
                    tone_cnt <= tone_cnt + 1;
                end if;
            end if;
        end if;
    end process;
    buzzer <= tone_wave;

    -- 5. Generador PWM de 50 Hz para Servomotor SG90
    process(CLOCK_50)
        variable duty : integer;
    begin
        if rising_edge(CLOCK_50) then
            if pwm_cnt < PWM_PERIOD - 1 then
                pwm_cnt <= pwm_cnt + 1;
            else
                pwm_cnt <= 0;
            end if;

            if cerrojo_int = '1' then
                duty := SERVO_90DEG; -- 1.5 ms -> 90° Abierto
            else
                duty := SERVO_0DEG;  -- 0.5 ms -> 0° Cerrado
            end if;

            if pwm_cnt < duty then
                servo_pwm <= '1';
            else
                servo_pwm <= '0';
            end if;
        end if;
    end process;

    -- 6. Lógica Combinacional de Salidas
    process(estado_actual, alerta_error, clk_1s_cnt)
    begin
        cerrojo_int <= '0';
        hab_huella  <= '0';
        leds_fase   <= "000";
        rgb_r       <= '0';
        rgb_g       <= '0';
        rgb_b       <= '0';
        ledr_estado <= "00000";

        case estado_actual is
            when S0_REPOSO_FACIAL =>
                leds_fase   <= "000";
                ledr_estado <= "00001";
                if alerta_error = '1' then rgb_r <= '1'; rgb_g <= '1'; else rgb_r <= '1'; end if;

            when S1_VOZ =>
                leds_fase   <= "001";
                ledr_estado <= "00010";
                if alerta_error = '1' then rgb_r <= '1'; rgb_g <= '1'; else rgb_r <= '1'; end if;

            when S2_HUELLA =>
                hab_huella  <= '1';
                leds_fase   <= "011";
                ledr_estado <= "00100";
                if alerta_error = '1' then rgb_r <= '1'; rgb_g <= '1'; else rgb_r <= '1'; end if;

            when S3_BOVEDA_ABIERTA =>
                cerrojo_int <= '1'; -- Mueve el servo a 90°
                leds_fase   <= "111";
                rgb_g       <= '1';
                ledr_estado <= "01000";

            when S4_BLOQUEO_TOTAL =>
                leds_fase   <= "000";
                ledr_estado <= "10000";
                if clk_1s_cnt < 12_500_000 or (clk_1s_cnt >= 25_000_000 and clk_1s_cnt < 37_500_000) then
                    rgb_r <= '1';
                else
                    rgb_r <= '0';
                end if;
        end case;
    end process;

    cerrojo_digital <= cerrojo_int;
    user_id         <= usuario_reg;

end Behavioral;