library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_transceiver is
    Generic (
        CLK_FREQ  : integer := 50_000_000;
        BAUD_RATE : integer := 9600
    );
    Port (
        clk       : in  STD_LOGIC;
        reset_n   : in  STD_LOGIC;
        -- Interfaz RX (desde ESP32 TX2 / CP2102 TXD)
        rx_serial : in  STD_LOGIC;
        rx_data   : out STD_LOGIC_VECTOR(7 downto 0);
        rx_valid  : out STD_LOGIC;
        -- Interfaz TX (hacia ESP32 RX2 / CP2102 RXD)
        tx_start  : in  STD_LOGIC;
        tx_data   : in  STD_LOGIC_VECTOR(7 downto 0);
        tx_serial : out STD_LOGIC;
        tx_busy   : out STD_LOGIC
    );
end uart_transceiver;

architecture Behavioral of uart_transceiver is
    constant CLKS_PER_BIT : integer := CLK_FREQ / BAUD_RATE; -- 5208 ciclos @ 50MHz

    -- Señales RX
    type rx_state_t is (RX_IDLE, RX_START_BIT, RX_DATA_BITS, RX_STOP_BIT);
    signal rx_state   : rx_state_t := RX_IDLE;
    signal rx_sync    : STD_LOGIC_VECTOR(1 downto 0) := "11";
    signal rx_clk_cnt : integer range 0 to CLKS_PER_BIT - 1 := 0;
    signal rx_bit_idx : integer range 0 to 7 := 0;
    signal rx_shift   : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');

    -- Señales TX
    type tx_state_t is (TX_IDLE, TX_START_BIT, TX_DATA_BITS, TX_STOP_BIT);
    signal tx_state   : tx_state_t := TX_IDLE;
    signal tx_clk_cnt : integer range 0 to CLKS_PER_BIT - 1 := 0;
    signal tx_bit_idx : integer range 0 to 7 := 0;
    signal tx_shift   : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
begin

    -- Sincronizador de doble flip-flop para evitar metaestabilidad en rx_serial
    process(clk)
    begin
        if rising_edge(clk) then
            rx_sync <= rx_sync(0) & rx_serial;
        end if;
    end process;

    -- Proceso Receptor UART (RX)
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            rx_state   <= RX_IDLE;
            rx_clk_cnt <= 0;
            rx_bit_idx <= 0;
            rx_data    <= (others => '0');
            rx_valid   <= '0';
        elsif rising_edge(clk) then
            rx_valid <= '0';

            case rx_state is
                when RX_IDLE =>
                    rx_clk_cnt <= 0;
                    rx_bit_idx <= 0;
                    if rx_sync(1) = '0' then
                        rx_state <= RX_START_BIT;
                    end if;

                when RX_START_BIT =>
                    if rx_clk_cnt = (CLKS_PER_BIT / 2) then
                        if rx_sync(1) = '0' then
                            rx_clk_cnt <= 0;
                            rx_state   <= RX_DATA_BITS;
                        else
                            rx_state <= RX_IDLE;
                        end if;
                    else
                        rx_clk_cnt <= rx_clk_cnt + 1;
                    end if;

                when RX_DATA_BITS =>
                    if rx_clk_cnt < CLKS_PER_BIT - 1 then
                        rx_clk_cnt <= rx_clk_cnt + 1;
                    else
                        rx_clk_cnt           <= 0;
                        rx_shift(rx_bit_idx) <= rx_sync(1);
                        if rx_bit_idx < 7 then
                            rx_bit_idx <= rx_bit_idx + 1;
                        else
                            rx_bit_idx <= 0;
                            rx_state   <= RX_STOP_BIT;
                        end if;
                    end if;

                when RX_STOP_BIT =>
                    if rx_clk_cnt < CLKS_PER_BIT - 1 then
                        rx_clk_cnt <= rx_clk_cnt + 1;
                    else
                        rx_clk_cnt <= 0;
                        rx_data    <= rx_shift;
                        rx_valid   <= '1';
                        rx_state   <= RX_IDLE;
                    end if;
            end case;
        end if;
    end process;

    -- Proceso Transmisor UART (TX)
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            tx_state   <= TX_IDLE;
            tx_serial  <= '1';
            tx_busy    <= '0';
            tx_clk_cnt <= 0;
            tx_bit_idx <= 0;
        elsif rising_edge(clk) then
            case tx_state is
                when TX_IDLE =>
                    tx_serial  <= '1';
                    tx_busy    <= '0';
                    tx_clk_cnt <= 0;
                    tx_bit_idx <= 0;
                    if tx_start = '1' then
                        tx_shift <= tx_data;
                        tx_busy  <= '1';
                        tx_state <= TX_START_BIT;
                    end if;

                when TX_START_BIT =>
                    tx_serial <= '0';
                    if tx_clk_cnt < CLKS_PER_BIT - 1 then
                        tx_clk_cnt <= tx_clk_cnt + 1;
                    else
                        tx_clk_cnt <= 0;
                        tx_state   <= TX_DATA_BITS;
                    end if;

                when TX_DATA_BITS =>
                    tx_serial <= tx_shift(tx_bit_idx);
                    if tx_clk_cnt < CLKS_PER_BIT - 1 then
                        tx_clk_cnt <= tx_clk_cnt + 1;
                    else
                        tx_clk_cnt <= 0;
                        if tx_bit_idx < 7 then
                            tx_bit_idx <= tx_bit_idx + 1;
                        else
                            tx_bit_idx <= 0;
                            tx_state   <= TX_STOP_BIT;
                        end if;
                    end if;

                when TX_STOP_BIT =>
                    tx_serial <= '1';
                    if tx_clk_cnt < CLKS_PER_BIT - 1 then
                        tx_clk_cnt <= tx_clk_cnt + 1;
                    else
                        tx_clk_cnt <= 0;
                        tx_busy    <= '0';
                        tx_state   <= TX_IDLE;
                    end if;
            end case;
        end if;
    end process;

end Behavioral;