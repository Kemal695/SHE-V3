package et.she.v3.dto;

import jakarta.validation.constraints.NotBlank;

public record RefreshRequest(@NotBlank String refresh_token) {}
