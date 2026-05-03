<?php

declare(strict_types=1);

function snomEnv(string $key, string $default = ''): string
{
    static $envLoaded = false;
    if (!$envLoaded) {
        $envFile = '/etc/snom-config/runtime.env';
        if (is_file($envFile) && is_readable($envFile)) {
            $lines = file($envFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
            foreach ($lines as $line) {
                if (str_starts_with(trim($line), '#') || !str_contains($line, '=')) {
                    continue;
                }
                [$k, $v] = explode('=', $line, 2);
                $_ENV[trim($k)] = trim($v);
            }
        }
        $envLoaded = true;
    }

    return $_ENV[$key] ?? $default;
}

function snomAudit(string $endpoint, int $status, string $detail = ''): void
{
    $logPath = snomEnv('AUDIT_LOG_PATH', '/var/log/snom-config/audit.log');
    $dir = dirname($logPath);
    if (!is_dir($dir)) {
        @mkdir($dir, 0750, true);
    }

    $ip = $_SERVER['REMOTE_ADDR'] ?? 'unknown';
    $user = $_SERVER['PHP_AUTH_USER'] ?? '-';
    $uri = $_SERVER['REQUEST_URI'] ?? '-';
    $line = sprintf(
        "%s ip=%s user=%s endpoint=%s status=%d uri=%s detail=%s\n",
        gmdate('c'),
        $ip,
        $user,
        $endpoint,
        $status,
        $uri,
        str_replace(["\n", "\r"], ' ', $detail)
    );

    $fh = @fopen($logPath, 'ab');
    if ($fh !== false) {
        flock($fh, LOCK_EX);
        fwrite($fh, $line);
        flock($fh, LOCK_UN);
        fclose($fh);
    }
}

function snomMaintenanceGuard(string $endpoint): void
{
    $adminIp = snomEnv('ADMIN_IP', '');
    $maintenanceFile = snomEnv('MAINTENANCE_FILE', '/etc/snom-config/maintenance.on');
    $ip = $_SERVER['REMOTE_ADDR'] ?? '';

    if (is_file($maintenanceFile) && ($adminIp === '' || $ip !== $adminIp)) {
        http_response_code(503);
        header('Content-Type: application/xml; charset=UTF-8');
        echo '<error>Maintenance aktiv.</error>';
        snomAudit($endpoint, 503, 'maintenance');
        exit;
    }
}
