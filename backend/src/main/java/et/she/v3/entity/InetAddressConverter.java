package et.she.v3.entity;

import jakarta.persistence.AttributeConverter;
import jakarta.persistence.Converter;

import java.net.InetAddress;
import java.net.UnknownHostException;

/**
 * Maps a {@code String} IP address to Postgres {@code inet} via {@link InetAddress}.
 *
 * The previous mapping (@JdbcTypeCode(SqlTypes.OTHER) on a String field) validated the
 * schema at startup but bound the value as {@code bytea} on INSERT, so any write to an
 * {@code inet} column failed with "column is of type inet but expression is of type bytea".
 *
 * Routing the value through {@link InetAddress} lets Hibernate use its native inet JDBC
 * binding, which works for both reads and writes.
 */
@Converter
public class InetAddressConverter implements AttributeConverter<String, InetAddress> {

    @Override
    public InetAddress convertToDatabaseColumn(String attribute) {
        if (attribute == null || attribute.isBlank()) return null;
        try {
            // getByName parses literal IPs (v4/v6) without performing DNS resolution.
            return InetAddress.getByName(attribute.trim());
        } catch (UnknownHostException e) {
            throw new IllegalArgumentException("Invalid IP address: " + attribute, e);
        }
    }

    @Override
    public String convertToEntityAttribute(InetAddress dbData) {
        return dbData == null ? null : dbData.getHostAddress();
    }
}
