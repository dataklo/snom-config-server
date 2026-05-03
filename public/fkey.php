<?php

declare(strict_types=1);

require_once __DIR__ . '/bootstrap.php';
snomMaintenanceGuard('fkey');

$baseDir = dirname(__DIR__) . '/data/config/fkey/';
$rawFile = isset($_GET['file']) ? (string) $_GET['file'] : 'default';
$file = basename(trim($rawFile));

if ($file === '' || !preg_match('/^[A-Za-z0-9._-]+$/', $file)) {
    http_response_code(400);
    header('Content-Type: application/xml; charset=UTF-8');
    echo '<error>Ungültiger Dateiname.</error>';
    snomAudit('fkey', 400, 'invalid filename');
    exit;
}

if (!str_ends_with($file, '.xml')) {
    $file .= '.xml';
}

$filePath = $baseDir . $file;

if (is_file($filePath) && is_readable($filePath)) {
    header('Content-Type: application/xml; charset=UTF-8');
    readfile($filePath);
    snomAudit('fkey', 200, basename($filePath));
    exit;
}

http_response_code(404);
header('Content-Type: application/xml; charset=UTF-8');
echo '<error>Angeforderte Datei nicht gefunden.</error>';
snomAudit('fkey', 404, $file);
