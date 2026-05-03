<?php

declare(strict_types=1);

require_once __DIR__ . '/bootstrap.php';
snomMaintenanceGuard('snomD385');

$version = isset($_GET['version']) ? trim((string) $_GET['version']) : '';

if ($version === '' || !preg_match('/^[0-9]+(?:\.[0-9]+){2,4}$/', $version)) {
    http_response_code(400);
    header('Content-Type: application/xml; charset=UTF-8');
    echo '<error>Ungültige oder fehlende Version.</error>';
    snomAudit('snomD385', 400, 'invalid version');
    exit;
}

$type = 'snomD385';
$firmwareUrl = sprintf(
    'https://downloads.snom.com/fw/%1$s/bin/%2$s-%1$s-SIP-r.bin',
    $version,
    $type
);

$dom = new DOMDocument('1.0', 'UTF-8');
$dom->formatOutput = true;

$root = $dom->createElement('firmware-settings');
$dom->appendChild($root);

$firmware = $dom->createElement('firmware', $firmwareUrl);
$firmware->setAttribute('perm', 'R');
$root->appendChild($firmware);

header('Content-Type: application/xml; charset=UTF-8');
echo $dom->saveXML();
snomAudit('snomD385', 200, $version);
