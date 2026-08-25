package et.she.v3.energy;

import java.util.List;

/**
 * ETB block tariff (Ethiopian Electric Utility residential rates).
 * V3-ENERGY-MONITORING §4.4.
 *
 * Blocks (kWh/month):
 *   1: 0-50    @ 0.78 ETB/kWh
 *   2: 51-100  @ 1.04 ETB/kWh
 *   3: 101-200 @ 1.30 ETB/kWh
 *   4: 201-300 @ 1.89 ETB/kWh
 *   5: 301-400 @ 2.67 ETB/kWh
 *   6: 400+    @ 4.50 ETB/kWh
 *
 * Commercial: flat 1.20 ETB/kWh (configurable per tenant).
 */
public record TariffBlock(Integer upperLimit, double pricePerKwh) {

    public static final List<TariffBlock> RESIDENTIAL = List.of(
            new TariffBlock(50,  0.78),
            new TariffBlock(100, 1.04),
            new TariffBlock(200, 1.30),
            new TariffBlock(300, 1.89),
            new TariffBlock(400, 2.67),
            new TariffBlock(null, 4.50)   // null = open-ended top block
    );

    public static final List<TariffBlock> COMMERCIAL = List.of(
            new TariffBlock(null, 1.20)
    );
}
