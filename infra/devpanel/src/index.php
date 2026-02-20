<?php
/**
 * DevPanel - Интерфейс управления Docker проектами
 * Доступ: https://docker.<DOMAIN_SUFFIX> (см. infra/.env.global)
 */

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
header('Pragma: no-cache');

// Для долгих AJAX-запросов (создание проекта) сразу поднимаем лимиты
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['action']) && $_POST['action'] === 'create' && (isset($_POST['ajax']) || isset($_GET['ajax']))) {
    set_time_limit(600);
    ini_set('max_execution_time', '600');
    ini_set('default_socket_timeout', 600);
    ignore_user_abort(true);
}

// Путь к проектам (монтируется как /projects в контейнере)
$projectsDir = '/projects';
if (!is_dir($projectsDir)) {
    // Fallback на относительный путь
    $projectsDir = realpath(__DIR__ . '/../../projects');
}

// Путь к состоянию/служебным данным (реестры, логи действий, фоновые job-артефакты)
$stateDir = '/state';
if (!is_dir($stateDir)) {
    $fallbackStateDir = realpath(__DIR__ . '/../../state');
    if (is_string($fallbackStateDir) && $fallbackStateDir !== '' && is_dir($fallbackStateDir)) {
        $stateDir = $fallbackStateDir;
    } elseif ($projectsDir && is_dir($projectsDir)) {
        $stateDir = rtrim($projectsDir, '/') . '/.state';
    } else {
        $stateDir = '';
    }
}
if ($stateDir !== '' && !is_dir($stateDir)) {
    @mkdir($stateDir, 0775, true);
}

function ensureStateDir($stateDir) {
    if (!is_string($stateDir) || $stateDir === '') {
        return false;
    }
    if (is_dir($stateDir)) {
        @chmod($stateDir, 0775);
        return true;
    }
    if (@mkdir($stateDir, 0775, true) || is_dir($stateDir)) {
        @chmod($stateDir, 0775);
        return true;
    }
    return false;
}

function getStatePathCandidates($stateDir, $projectsDir, $legacyName, $newName) {
    $candidates = [];
    if (is_string($stateDir) && $stateDir !== '') {
        $candidates[] = rtrim($stateDir, '/') . '/' . $newName;
        $candidates[] = rtrim($stateDir, '/') . '/' . $legacyName;
    }
    if (is_string($projectsDir) && $projectsDir !== '') {
        $candidates[] = rtrim($projectsDir, '/') . '/' . $legacyName;
    }
    return $candidates;
}

function resolveReadableStatePath(array $candidates) {
    foreach ($candidates as $path) {
        if (is_string($path) && $path !== '' && is_file($path) && is_readable($path)) {
            return $path;
        }
    }
    return null;
}

function copyDirectoryRecursive($src, $dst) {
    if (!is_dir($src)) {
        return false;
    }
    if (!is_dir($dst) && !@mkdir($dst, 0775, true) && !is_dir($dst)) {
        return false;
    }
    @chmod($dst, 0775);
    $items = @scandir($src);
    if (!is_array($items)) {
        return false;
    }
    foreach ($items as $item) {
        if ($item === '.' || $item === '..') {
            continue;
        }
        $sourceItem = rtrim($src, '/') . '/' . $item;
        $targetItem = rtrim($dst, '/') . '/' . $item;
        if (is_dir($sourceItem)) {
            if (!copyDirectoryRecursive($sourceItem, $targetItem)) {
                return false;
            }
        } else {
            if (!@copy($sourceItem, $targetItem)) {
                return false;
            }
        }
    }
    return true;
}

function deleteDirectoryRecursive($path) {
    if (!is_dir($path)) {
        return true;
    }
    $items = @scandir($path);
    if (!is_array($items)) {
        return false;
    }
    foreach ($items as $item) {
        if ($item === '.' || $item === '..') {
            continue;
        }
        $itemPath = rtrim($path, '/') . '/' . $item;
        if (is_dir($itemPath)) {
            deleteDirectoryRecursive($itemPath);
        } else {
            @unlink($itemPath);
        }
    }
    return @rmdir($path);
}

function migrateLegacyStateFile($legacyPath, $targetPath) {
    if (!is_string($legacyPath) || !is_string($targetPath) || $legacyPath === '' || $targetPath === '') {
        return;
    }
    if (!file_exists($legacyPath) || file_exists($targetPath)) {
        return;
    }

    $targetDir = dirname($targetPath);
    if (!is_dir($targetDir) && !@mkdir($targetDir, 0775, true) && !is_dir($targetDir)) {
        return;
    }

    if (@rename($legacyPath, $targetPath)) {
        return;
    }

    if (is_dir($legacyPath)) {
        if (copyDirectoryRecursive($legacyPath, $targetPath)) {
            deleteDirectoryRecursive($legacyPath);
        }
        return;
    }

    if (@copy($legacyPath, $targetPath)) {
        @unlink($legacyPath);
    }
}

function migrateLegacyStateLayout($projectsDir, $stateDir) {
    if (!ensureStateDir($stateDir) || !is_string($projectsDir) || $projectsDir === '') {
        return;
    }

    $legacyToNew = [
        '.hosts-registry.tsv' => 'hosts-registry.tsv',
        '.bitrix-core-registry.tsv' => 'bitrix-core-registry.tsv',
        '.bitrix-bindings.tsv' => 'bitrix-bindings.tsv',
        '.devpanel-actions.log' => 'devpanel-actions.log',
        '.devpanel-jobs' => 'devpanel-jobs',
    ];

    foreach ($legacyToNew as $legacyName => $newName) {
        $legacyPath = rtrim($projectsDir, '/') . '/' . $legacyName;
        $targetPath = rtrim($stateDir, '/') . '/' . $newName;
        migrateLegacyStateFile($legacyPath, $targetPath);
    }
}

migrateLegacyStateLayout((string)$projectsDir, (string)$stateDir);

$projects = [];
if ($projectsDir && is_dir($projectsDir)) {
    $dirs = scandir($projectsDir);
    foreach ($dirs as $dir) {
        if ($dir === '.' || $dir === '..') continue;
        $projectPath = $projectsDir . '/' . $dir;
        if (is_dir($projectPath) && file_exists($projectPath . '/docker-compose.yml')) {
            $projects[] = [
                'name' => $dir,
                'path' => $projectPath,
                'compose_file' => $projectPath . '/docker-compose.yml',
            ];
        }
    }
}
$hostctlScript = '/scripts/hostctl.sh';

// === Active zone (DOMAIN_SUFFIX) helpers for WP04 ===
function devpanel_resolve_domain_suffix() {
    $raw = getenv('DOMAIN_SUFFIX');
    if ($raw === false || $raw === '') {
        $raw = 'loc';
    }
    $suffix = strtolower(trim(preg_replace('/^[\s"\']+|[\s"\']+$/u', '', $raw)));
    if ($suffix === '') {
        return ['suffix' => null, 'error' => 'DOMAIN_SUFFIX не задан. Настройте в infra/.env.global.'];
    }
    if (!preg_match('/^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$/', $suffix) || strlen($suffix) > 63) {
        return ['suffix' => null, 'error' => "Некорректный DOMAIN_SUFFIX '$suffix'. Ожидается DNS-метка до 63 символов."];
    }
    return ['suffix' => $suffix, 'error' => null];
}

function devpanel_service_domains($suffix) {
    return [
        'docker' => 'docker.' . $suffix,
        'traefik' => 'traefik.' . $suffix,
        'adminer' => 'adminer.' . $suffix,
        'grafana' => 'grafana.' . $suffix,
    ];
}

function devpanel_is_legacy_host($host, $suffix) {
    if ($suffix === '' || $suffix === null) return false;
    if (preg_match('/\.([a-z0-9][a-z0-9-]{0,30})$/i', $host, $m)) {
        return strtolower($m[1]) !== strtolower($suffix);
    }
    return true;
}

function devpanel_canonicalize_host($input, $suffix, $mode = 'existing') {
    $normalized = strtolower(trim(preg_replace('/^[\s"\']+|[\s"\']+$/u', '', $input)));
    if ($normalized === '') {
        return ['canonical' => null, 'error' => 'Пустое имя хоста.'];
    }
    if (preg_match('/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/i', $normalized) && strlen($normalized) <= 63) {
        return ['canonical' => $normalized . '.' . $suffix, 'error' => null];
    }
    if (preg_match('/^([a-z0-9][a-z0-9-]{0,62})\.([a-z0-9][a-z0-9-]{0,30})$/i', $normalized, $m)) {
        $hostLabel = $m[1];
        $hostSuffix = strtolower($m[2]);
        if ($hostSuffix === $suffix) {
            return ['canonical' => $hostLabel . '.' . $suffix, 'error' => null];
        }
        if ($mode === 'create') {
            return ['canonical' => null, 'error' => "Хост '$input' использует суффикс '$hostSuffix'. Разрешена только активная зона '$suffix'."];
        }
        return ['canonical' => $hostLabel . '.' . $hostSuffix, 'error' => null];
    }
    return ['canonical' => null, 'error' => "Некорректное имя хоста '$input'. Допустимо: <name> или <name>.$suffix"];
}

$domainZone = devpanel_resolve_domain_suffix();
$domainSuffix = $domainZone['suffix'] ?? 'loc';
$domainZoneError = $domainZone['error'] ?? null;
$serviceDomains = $domainSuffix ? devpanel_service_domains($domainSuffix) : ['docker' => 'docker.loc', 'traefik' => 'traefik.loc', 'adminer' => 'adminer.loc', 'grafana' => 'grafana.loc'];

// Парсинг .env / .env.example: все пары KEY=VALUE в массив
function parseEnvFile($projectPath) {
    $env = [];
    foreach (['.env', '.env.example'] as $file) {
        $path = $projectPath . '/' . $file;
        if (!is_file($path) || !is_readable($path)) continue;
        $lines = file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        foreach ($lines as $line) {
            $line = trim($line);
            if ($line === '' || $line[0] === '#') continue;
            if (strpos($line, '=') !== false) {
                $eq = strpos($line, '=');
                $key = trim(substr($line, 0, $eq));
                $val = trim(substr($line, $eq + 1), " \t\"'");
                $env[$key] = $val;
            }
        }
        break; // используем первый найденный файл
    }
    return $env;
}

function parseHostsRegistry($stateDir, $projectsDir) {
    $registry = [];
    $path = resolveReadableStatePath(getStatePathCandidates($stateDir, $projectsDir, '.hosts-registry.tsv', 'hosts-registry.tsv'));
    if ($path === null) {
        return $registry;
    }

    $lines = file($path, FILE_IGNORE_NEW_LINES);
    foreach ($lines as $line) {
        if ($line === null || trim($line) === '') continue;
        $parts = explode("\t", $line);
        if (count($parts) < 1 || trim($parts[0]) === '') continue;
        $host = trim($parts[0]);
        $registry[$host] = [
            'preset' => $parts[1] ?? null,
            'php_version' => $parts[2] ?? null,
            'db_type' => $parts[3] ?? null,
            'created_at' => $parts[4] ?? null,
            'bitrix_type' => $parts[5] ?? null,
            'core_id' => $parts[6] ?? null,
        ];
    }

    return $registry;
}

function parseBitrixCoreRegistry($stateDir, $projectsDir) {
    $byCoreId = [];
    $byOwnerHost = [];
    $path = resolveReadableStatePath(getStatePathCandidates($stateDir, $projectsDir, '.bitrix-core-registry.tsv', 'bitrix-core-registry.tsv'));
    if ($path === null) {
        return [$byCoreId, $byOwnerHost];
    }

    $lines = file($path, FILE_IGNORE_NEW_LINES);
    foreach ($lines as $line) {
        if ($line === null || trim($line) === '') continue;
        $parts = explode("\t", $line);
        if (count($parts) < 3) continue;

        $coreId = trim($parts[0]);
        $owner = trim($parts[1]);
        $coreType = trim($parts[2]);
        if ($coreId === '' || $owner === '') continue;

        $record = [
            'core_id' => $coreId,
            'owner_host' => $owner,
            'core_type' => $coreType,
            'created_at' => $parts[3] ?? null,
        ];
        $byCoreId[$coreId] = $record;
        $byOwnerHost[$owner] = $record;
    }

    return [$byCoreId, $byOwnerHost];
}

function parseBitrixBindingsRegistry($stateDir, $projectsDir) {
    $byHost = [];
    $linksByCore = [];
    $path = resolveReadableStatePath(getStatePathCandidates($stateDir, $projectsDir, '.bitrix-bindings.tsv', 'bitrix-bindings.tsv'));
    if ($path === null) {
        return [$byHost, $linksByCore];
    }

    $lines = file($path, FILE_IGNORE_NEW_LINES);
    foreach ($lines as $line) {
        if ($line === null || trim($line) === '') continue;
        $parts = explode("\t", $line);
        if (count($parts) < 2) continue;

        $host = trim($parts[0]);
        $coreId = trim($parts[1]);
        if ($host === '' || $coreId === '') continue;

        $byHost[$host] = $coreId;
        if (!isset($linksByCore[$coreId])) {
            $linksByCore[$coreId] = [];
        }
        $linksByCore[$coreId][] = $host;
    }

    return [$byHost, $linksByCore];
}

function logDevpanelAction($stateDir, $action, $status, $context = []) {
    if (!ensureStateDir($stateDir)) {
        return;
    }

    $logFile = rtrim($stateDir, '/') . '/devpanel-actions.log';
    $timestamp = gmdate('Y-m-d\TH:i:s\Z');
    $record = [
        'ts' => $timestamp,
        'action' => $action,
        'status' => $status,
        'context' => $context,
    ];

    @file_put_contents(
        $logFile,
        json_encode($record, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . PHP_EOL,
        FILE_APPEND
    );
}

function detectCreateErrorKind($outputText) {
    $normalized = strtolower((string)$outputText);
    if ($normalized === '') {
        return 'generic';
    }

    if (strpos($normalized, 'already exists') !== false || strpos($normalized, 'уже существует') !== false) {
        return 'conflict';
    }
    if (strpos($normalized, 'foreign_suffix') !== false || strpos($normalized, 'foreign suffix') !== false
        || strpos($normalized, 'использует суффикс') !== false || strpos($normalized, 'invalid_domain_suffix') !== false) {
        return 'foreign_suffix';
    }
    if (strpos($normalized, 'invalid_host') !== false || strpos($normalized, 'invalid host') !== false) {
        return 'invalid_host';
    }

    if (
        strpos($normalized, 'mounts denied') !== false ||
        strpos($normalized, 'not shared from the host') !== false ||
        strpos($normalized, 'permission denied') !== false
    ) {
        return 'infra';
    }

    return 'generic';
}

function extractDbHostFromEnv(array $env) {
    $candidates = ['DB_SERVICE_NAME', 'DB_HOST', 'MYSQL_HOST', 'POSTGRES_HOST'];
    foreach ($candidates as $key) {
        if (!array_key_exists($key, $env)) {
            continue;
        }
        $value = trim((string)$env[$key]);
        if ($value !== '') {
            return $value;
        }
    }
    return null;
}

function inferDbHostFromCompose($yaml, $dbType = null) {
    if (!is_string($yaml) || trim($yaml) === '') {
        return null;
    }

    $lines = preg_split('/\R/', $yaml);
    if (!is_array($lines)) {
        return null;
    }

    $inServices = false;
    $currentService = null;
    $services = [];
    $serviceImages = [];

    foreach ($lines as $line) {
        if (preg_match('/^\s*services:\s*$/', $line)) {
            $inServices = true;
            $currentService = null;
            continue;
        }
        if (!$inServices) {
            continue;
        }

        // Выход из секции services при переходе к следующей top-level секции.
        if (preg_match('/^[^\s#][^:]*:\s*$/', $line)) {
            break;
        }

        if (preg_match('/^  ([A-Za-z0-9][A-Za-z0-9_.-]*):\s*$/', $line, $serviceMatch)) {
            $currentService = $serviceMatch[1];
            $services[] = $currentService;
            continue;
        }

        if ($currentService !== null && preg_match('/^\s{4}image:\s*(.+?)\s*$/i', $line, $imageMatch)) {
            $serviceImages[$currentService] = strtolower(trim($imageMatch[1], " \t\"'"));
        }
    }

    foreach ($services as $serviceName) {
        if (strpos($serviceName, 'db-') === 0) {
            return $serviceName;
        }
    }

    $dbTypeNormalized = strtolower(trim((string)$dbType));
    if ($dbTypeNormalized === 'mysql') {
        if (in_array('mysql', $services, true)) {
            return 'mysql';
        }
        foreach ($serviceImages as $serviceName => $image) {
            if (strpos($image, 'mysql') !== false || strpos($image, 'mariadb') !== false) {
                return $serviceName;
            }
        }
    }

    if ($dbTypeNormalized === 'postgresql') {
        if (in_array('postgres', $services, true)) {
            return 'postgres';
        }
        foreach ($serviceImages as $serviceName => $image) {
            if (strpos($image, 'postgres') !== false) {
                return $serviceName;
            }
        }
    }

    foreach ($serviceImages as $serviceName => $image) {
        if (
            strpos($image, 'mysql') !== false ||
            strpos($image, 'mariadb') !== false ||
            strpos($image, 'postgres') !== false
        ) {
            return $serviceName;
        }
    }

    return null;
}

// Метаданные проекта: PHP версия, БД, пресет, домен, env
function getProjectMetadata($projectPath, $hostsRegistry, $bitrixCoreByOwner, $bitrixBindingByHost) {
    $meta = [
        'php_version' => null,
        'db_type' => null,
        'db_host' => null,
        'preset' => null,
        'domain' => basename($projectPath),
        'bitrix_type' => null,
        'core_id' => null,
        'env' => [],
    ];
    $hostName = basename($projectPath);
    $composeFile = $projectPath . '/docker-compose.yml';
    if (!is_file($composeFile) || !is_readable($composeFile)) {
        $meta['env'] = parseEnvFile($projectPath);
        $meta['db_host'] = extractDbHostFromEnv($meta['env']);
        return $meta;
    }
    $yaml = @file_get_contents($composeFile);
    if ($yaml === false) {
        $meta['env'] = parseEnvFile($projectPath);
        $meta['db_host'] = extractDbHostFromEnv($meta['env']);
        return $meta;
    }
    // Dockerfile: Dockerfile.php84 -> 8.4, Dockerfile.php81 -> 8.1
    if (preg_match('/dockerfile:\s*Dockerfile\.php(\d)(\d)/i', $yaml, $m)) {
        $meta['php_version'] = $m[1] . '.' . $m[2];
    }
    if (stripos($yaml, 'mysql:') !== false || preg_match('/image:\s*mysql/i', $yaml)) {
        $meta['db_type'] = 'MySQL';
    } elseif (stripos($yaml, 'postgres') !== false || preg_match('/image:\s*postgres/i', $yaml)) {
        $meta['db_type'] = 'PostgreSQL';
    }
    $readme = $projectPath . '/README.md';
    if (is_file($readme) && is_readable($readme)) {
        $head = trim(file_get_contents($readme, false, null, 0, 500));
        if (stripos($head, 'Bitrix') !== false) $meta['preset'] = 'Bitrix';
        elseif (stripos($head, 'Laravel') !== false) $meta['preset'] = 'Laravel';
        elseif (stripos($head, 'WordPress') !== false) $meta['preset'] = 'WordPress';
        elseif (stripos($head, 'Static') !== false) $meta['preset'] = 'Static';
        else $meta['preset'] = 'PHP';
    }

    if (isset($hostsRegistry[$hostName])) {
        $registryBitrixType = trim((string)($hostsRegistry[$hostName]['bitrix_type'] ?? ''));
        $registryCoreId = trim((string)($hostsRegistry[$hostName]['core_id'] ?? ''));
        if ($registryBitrixType !== '' && $registryBitrixType !== '-') {
            $meta['bitrix_type'] = $registryBitrixType;
        }
        if ($registryCoreId !== '' && $registryCoreId !== '-') {
            $meta['core_id'] = $registryCoreId;
        }
    }

    if ($meta['bitrix_type'] === null && isset($bitrixBindingByHost[$hostName])) {
        $meta['bitrix_type'] = 'link';
        $meta['core_id'] = $bitrixBindingByHost[$hostName];
    }

    if ($meta['bitrix_type'] === null && isset($bitrixCoreByOwner[$hostName])) {
        $meta['bitrix_type'] = $bitrixCoreByOwner[$hostName]['core_type'] ?? 'kernel';
        $meta['core_id'] = $bitrixCoreByOwner[$hostName]['core_id'] ?? null;
    }

    $meta['env'] = parseEnvFile($projectPath);
    $meta['db_host'] = extractDbHostFromEnv($meta['env']);
    if ($meta['db_host'] === null) {
        $meta['db_host'] = inferDbHostFromCompose($yaml, $meta['db_type']);
    }

    return $meta;
}

// Получение конфигурации контейнера через docker inspect
function getContainerConfig($containerName) {
    $output = [];
    exec("docker inspect {$containerName} --format '{{json .}}' 2>&1", $output, $return);
    
    if ($return !== 0 || empty($output)) {
        return null;
    }
    
    $json = json_decode(implode('', $output), true);
    if (!$json) {
        return null;
    }
    
    $config = [
        'image' => $json['Config']['Image'] ?? '',
        'ports' => [],
        'volumes' => [],
        'environment' => [],
        'networks' => [],
        'command' => $json['Config']['Cmd'] ?? [],
        'working_dir' => $json['Config']['WorkingDir'] ?? '',
    ];
    
    // Порты
    if (isset($json['NetworkSettings']['Ports'])) {
        foreach ($json['NetworkSettings']['Ports'] as $port => $mapping) {
            if ($mapping) {
                $config['ports'][] = $port . ' -> ' . ($mapping[0]['HostPort'] ?? '') . ':' . ($mapping[0]['HostIp'] ?? '0.0.0.0');
            } else {
                $config['ports'][] = $port;
            }
        }
    }
    
    // Volumes
    if (isset($json['Mounts'])) {
        foreach ($json['Mounts'] as $mount) {
            $config['volumes'][] = ($mount['Source'] ?? '') . ' -> ' . ($mount['Destination'] ?? '') . ' (' . ($mount['Type'] ?? '') . ')';
        }
    }
    
    // Environment
    if (isset($json['Config']['Env'])) {
        $config['environment'] = $json['Config']['Env'];
    }
    
    // Networks
    if (isset($json['NetworkSettings']['Networks'])) {
        foreach ($json['NetworkSettings']['Networks'] as $network => $details) {
            $config['networks'][] = $network . ' (' . ($details['IPAddress'] ?? '') . ')';
        }
    }
    
    return $config;
}

// Получение статуса контейнеров проекта
// Контейнер devpanel уже работает от root, поэтому команды выполняются напрямую
function getProjectContainers($projectName) {
    $containers = [];
    $output = [];
    exec("docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}' --filter 'name={$projectName}' 2>&1", $output, $return);
    
    // Если ошибка доступа к docker
    if ($return !== 0 && !empty($output)) {
        $errorMsg = implode(' ', $output);
        if (stripos($errorMsg, 'permission') !== false || stripos($errorMsg, 'denied') !== false) {
            return [['name' => 'Ошибка доступа', 'status' => 'permission denied', 'image' => '']];
        }
    }
    
    foreach ($output as $line) {
        if (empty(trim($line))) continue;
        // Пропускаем строки с ошибками
        if (stripos($line, 'permission') !== false || stripos($line, 'denied') !== false) {
            continue;
        }
        $parts = preg_split('/\s+/', $line, 3);
        if (count($parts) >= 2) {
            $containerName = $parts[0];
            $containers[] = [
                'name' => $containerName,
                'status' => $parts[1] ?? 'unknown',
                'image' => $parts[2] ?? '',
                'config' => getContainerConfig($containerName),
            ];
        }
    }
    return $containers;
}

/**
 * Статус инфраструктурных контейнеров (Traefik, Adminer, Grafana, DevPanel).
 * Возвращает ['services' => [...], 'lastCheck' => ISO8601, 'error' => bool].
 * При ошибке Docker: error=true, services=[], lastCheck заполнен (FR-009).
 */
function getInfraStatus() {
    $lastCheck = gmdate('Y-m-d\TH:i:s\Z');
    $output = [];
    exec("docker ps -a --format '{{.Names}}\t{{.Status}}' 2>&1", $output, $return);

    if ($return !== 0) {
        return ['services' => [], 'lastCheck' => $lastCheck, 'error' => true];
    }

    $services = [
        'traefik' => ['name' => 'Traefik', 'status' => 'Down', 'container' => null],
        'adminer' => ['name' => 'Adminer', 'status' => 'Down', 'container' => null],
        'redis' => ['name' => 'Redis', 'status' => 'Down', 'container' => null],
        'loki' => ['name' => 'Loki', 'status' => 'Down', 'container' => null],
        'promtail' => ['name' => 'Promtail', 'status' => 'Down', 'container' => null],
        'grafana' => ['name' => 'Grafana', 'status' => 'Down', 'container' => null],
        'devpanel' => ['name' => 'DevPanel', 'status' => 'Down', 'container' => null],
    ];

    foreach ($output as $line) {
        $line = trim($line);
        if ($line === '') continue;
        $parts = preg_split('/\s+/', $line, 2);
        $containerName = $parts[0] ?? '';
        $name = strtolower($containerName);
        $status = $parts[1] ?? '';
        $isUp = (strpos($status, 'Up') === 0);

        if ($name === 'traefik') {
            $services['traefik']['status'] = $isUp ? 'Up' : 'Down';
            $services['traefik']['container'] = $containerName;
        } elseif ($name === 'adminer') {
            $services['adminer']['status'] = $isUp ? 'Up' : 'Down';
            $services['adminer']['container'] = $containerName;
        } elseif ($name === 'redis') {
            $services['redis']['status'] = $isUp ? 'Up' : 'Down';
            $services['redis']['container'] = $containerName;
        } elseif ($name === 'loki') {
            $services['loki']['status'] = $isUp ? 'Up' : 'Down';
            $services['loki']['container'] = $containerName;
        } elseif ($name === 'promtail') {
            $services['promtail']['status'] = $isUp ? 'Up' : 'Down';
            $services['promtail']['container'] = $containerName;
        } elseif ($name === 'grafana') {
            $services['grafana']['status'] = $isUp ? 'Up' : 'Down';
            $services['grafana']['container'] = $containerName;
        } elseif ($name === 'devpanel' || $name === 'devpanel-fallback') {
            $services['devpanel']['status'] = $isUp ? 'Up' : 'Down';
            $services['devpanel']['container'] = $containerName;
        }
    }

    return ['services' => $services, 'lastCheck' => $lastCheck, 'error' => false];
}

/**
 * Сводка по проектам: сколько всего и сколько запущено.
 * Один вызов docker ps -a, группировка по префиксу имени контейнера.
 */
function getProjectsStatusSummary(array $projects) {
    $output = [];
    exec("docker ps -a --format '{{.Names}}\t{{.Status}}' 2>&1", $output, $return);
    $runningByProject = [];
    $totalByProject = [];
    foreach ($projects as $p) {
        $name = $p['name'];
        $runningByProject[$name] = 0;
        $totalByProject[$name] = 0;
    }
    foreach ($output as $line) {
        $line = trim($line);
        if ($line === '' || stripos($line, 'permission') !== false || stripos($line, 'denied') !== false) continue;
        $parts = preg_split('/\s+/', $line, 2);
        $containerName = $parts[0] ?? '';
        $status = $parts[1] ?? '';
        $isUp = (strpos($status, 'Up') === 0);
        $projList = $projects;
        usort($projList, function ($a, $b) { return strlen($b['name']) - strlen($a['name']); });
        foreach ($projList as $p) {
            $name = $p['name'];
            $norm = str_replace('.', '-', $name);
            $prefixes = [$name . '-', $name . '_', $norm . '-', $norm . '_'];
            $matched = ($containerName === $name);
            foreach ($prefixes as $pref) {
                if (strpos($containerName, $pref) === 0) { $matched = true; break; }
            }
            if ($matched) {
                $totalByProject[$name]++;
                if ($isUp) $runningByProject[$name]++;
                break;
            }
        }
    }
    $totalRunning = array_sum($runningByProject);
    $totalProjects = count($projects);
    $projectsWithRunning = count(array_filter($runningByProject));
    return ['total' => $totalProjects, 'running' => $projectsWithRunning, 'containersUp' => $totalRunning];
}

$currentPage = trim($_GET['page'] ?? 'projects');
$validPages = ['projects', 'infra', 'hosts', 'help'];
if (!in_array($currentPage, $validPages, true)) {
    $currentPage = 'projects';
}
$infraStatus = null;
try {
    $infraStatus = getInfraStatus();
} catch (Throwable $e) {
    $infraStatus = ['services' => [], 'lastCheck' => gmdate('Y-m-d\TH:i:s\Z'), 'error' => true];
}
$headerProjectSummary = getProjectsStatusSummary($projects);

$hostsRegistry = parseHostsRegistry($stateDir, $projectsDir);
[$bitrixCoreById, $bitrixCoreByOwner] = ($projectsDir && is_dir($projectsDir))
    ? parseBitrixCoreRegistry($stateDir, $projectsDir)
    : [[], []];
[$bitrixBindingByHost, $bitrixLinksByCore] = ($projectsDir && is_dir($projectsDir))
    ? parseBitrixBindingsRegistry($stateDir, $projectsDir)
    : [[], []];

// Обработка действий
$actionResult = null;
$isAjax = isset($_GET['ajax']) || isset($_POST['ajax']) || (isset($_SERVER['HTTP_X_REQUESTED_WITH']) && strtolower($_SERVER['HTTP_X_REQUESTED_WITH']) === 'xmlhttprequest');

if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['action'])) {
    $action = $_POST['action'];
    
    switch ($action) {
        case 'create':
            $projectNameRaw = trim($_POST['project_name'] ?? '');
            $phpVersion = $_POST['php_version'] ?? '8.2';
            $dbType = $_POST['db_type'] ?? 'mysql';
            $preset = $_POST['preset'] ?? 'php';
            $bitrixType = trim($_POST['bitrix_type'] ?? 'kernel');
            $coreId = trim($_POST['core_id'] ?? '');

            if ($domainZoneError !== null) {
                $actionResult = ['type' => 'error', 'message' => $domainZoneError];
                break;
            }
            // ext_kernel: core_id без доменной зоны (core-main-shop), остальные — домен
            if ($preset === 'bitrix' && $bitrixType === 'ext_kernel') {
                $normalized = strtolower(trim(preg_replace('/^[\s"\']+|[\s"\']+$/u', '', $projectNameRaw)));
                if ($normalized === '') {
                    $actionResult = ['type' => 'error', 'message' => 'Пустое имя проекта (core_id).'];
                    break;
                }
                if (!preg_match('/^[a-z0-9][a-z0-9-]{1,62}$/', $normalized)) {
                    $actionResult = ['type' => 'error', 'message' => "Некорректный core_id '$projectNameRaw'. Допустимо: a-z, 0-9, дефис; 2–63 символа."];
                    break;
                }
                $projectName = $normalized;
            } else {
                $canon = devpanel_canonicalize_host($projectNameRaw, $domainSuffix, 'create');
                if ($canon['error'] !== null) {
                    $actionResult = ['type' => 'error', 'message' => $canon['error']];
                    break;
                }
                $projectName = $canon['canonical'];
            }

            if (!empty($projectName) && preg_match('/^[a-z0-9\-\.]+$/i', $projectName)) {
                if (file_exists($hostctlScript)) {
                    $cmdParts = [
                        'bash',
                        escapeshellarg($hostctlScript),
                        'create',
                        escapeshellarg($projectName),
                        '--php',
                        escapeshellarg($phpVersion),
                        '--db',
                        escapeshellarg($dbType),
                        '--preset',
                        escapeshellarg($preset),
                        '--no-interactive',
                    ];

                    if ($preset === 'bitrix') {
                        if (!in_array($bitrixType, ['kernel', 'ext_kernel', 'link'], true)) {
                            $actionResult = ['type' => 'error', 'message' => 'Некорректный Bitrix type. Допустимо: kernel, ext_kernel, link.'];
                            break;
                        }

                        $cmdParts[] = '--bitrix-type';
                        $cmdParts[] = escapeshellarg($bitrixType);

                        if ($coreId !== '') {
                            if (!preg_match('/^[a-z0-9][a-z0-9-]{1,62}$/', $coreId)) {
                                $actionResult = ['type' => 'error', 'message' => 'Некорректный core_id. Разрешены: a-z, 0-9, дефис; длина 2..63.'];
                                break;
                            }
                        }

                        if ($bitrixType === 'link') {
                            if ($coreId === '') {
                                $actionResult = ['type' => 'error', 'message' => 'Для link-хоста требуется указать core_id.'];
                                break;
                            }
                            $cmdParts[] = '--core';
                            $cmdParts[] = escapeshellarg($coreId);
                        } elseif ($coreId !== '') {
                            $cmdParts[] = '--core-id';
                            $cmdParts[] = escapeshellarg($coreId);
                        }
                    }

                    // Для AJAX: запускаем создание в фоне, чтобы не рвать долгий HTTP-запрос
                    if ($isAjax) {
                        $jobsDir = $stateDir !== '' ? rtrim((string)$stateDir, '/') . '/devpanel-jobs' : '';
                        if ($jobsDir === '' || (!is_dir($jobsDir) && !@mkdir($jobsDir, 0775, true) && !is_dir($jobsDir))) {
                            $actionResult = ['type' => 'error', 'message' => 'Не удалось создать каталог фоновых задач DevPanel.'];
                            if (!headers_sent()) {
                                header('Content-Type: application/json; charset=utf-8');
                            }
                            echo json_encode($actionResult, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
                            exit;
                        }
                        @chmod($jobsDir, 0775);

                        try {
                            $jobId = 'create_' . gmdate('Ymd_His') . '_' . bin2hex(random_bytes(4));
                        } catch (Throwable $e) {
                            $jobId = 'create_' . gmdate('Ymd_His') . '_' . uniqid();
                        }

                        $jobLogFile = $jobsDir . '/' . $jobId . '.log';
                        $jobExitFile = $jobsDir . '/' . $jobId . '.exit';
                        $jobMetaFile = $jobsDir . '/' . $jobId . '.json';
                        $jobScriptFile = $jobsDir . '/' . $jobId . '.sh';
                        $command = implode(' ', $cmdParts);

                        $scriptBody = "#!/usr/bin/env bash\n"
                            . "set -u\n"
                            . "rm -f " . escapeshellarg($jobExitFile) . "\n"
                            . $command . " > " . escapeshellarg($jobLogFile) . " 2>&1\n"
                            . "echo \$? > " . escapeshellarg($jobExitFile) . "\n";

                        if (@file_put_contents($jobScriptFile, $scriptBody) === false) {
                            $actionResult = ['type' => 'error', 'message' => 'Не удалось создать скрипт фоновой задачи.'];
                            if (!headers_sent()) {
                                header('Content-Type: application/json; charset=utf-8');
                            }
                            echo json_encode($actionResult, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
                            exit;
                        }
                        @chmod($jobScriptFile, 0700);

                        $meta = [
                            'job_id' => $jobId,
                            'action' => 'create',
                            'project' => $projectName,
                            'preset' => $preset,
                            'bitrix_type' => $preset === 'bitrix' ? $bitrixType : null,
                            'core_id' => $coreId !== '' ? $coreId : null,
                            'command' => $command,
                            'created_at' => gmdate('Y-m-d\TH:i:s\Z'),
                            'status' => 'running',
                            'result_logged' => false,
                        ];
                        @file_put_contents($jobMetaFile, json_encode($meta, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));

                        $pidOutput = [];
                        $launchCode = 1;
                        $launchCmd = 'nohup bash ' . escapeshellarg($jobScriptFile) . ' >/dev/null 2>&1 & echo $!';
                        @exec($launchCmd, $pidOutput, $launchCode);
                        $pid = trim((string)($pidOutput[0] ?? ''));

                        if ($launchCode !== 0 || $pid === '') {
                            $actionResult = ['type' => 'error', 'message' => 'Не удалось запустить фоновую задачу создания проекта.'];
                            if (!headers_sent()) {
                                header('Content-Type: application/json; charset=utf-8');
                            }
                            echo json_encode($actionResult, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
                            exit;
                        }

                        $meta['pid'] = $pid;
                        @file_put_contents($jobMetaFile, json_encode($meta, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
                        logDevpanelAction($stateDir, 'create', 'pending', [
                            'project' => $projectName,
                            'job_id' => $jobId,
                            'pid' => $pid,
                            'command' => $command,
                        ]);

                        $actionResult = [
                            'type' => 'pending',
                            'status' => 'running',
                            'message' => "Создание проекта {$projectName} запущено",
                            'job_id' => $jobId,
                            'offset' => 0,
                        ];
                        if (!headers_sent()) {
                            header('Content-Type: application/json; charset=utf-8');
                            header('Cache-Control: no-cache, must-revalidate');
                        }
                        echo json_encode($actionResult, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
                        exit;
                    }

                    // Дублируем лимиты (уже выставлены в начале скрипта для create+ajax)
                    set_time_limit(600);
                    ini_set('max_execution_time', 600);
                    
                    $cmd = implode(' ', $cmdParts) . ' 2>&1';
                    $output = [];
                    $startTime = microtime(true);
                    $fullOutput = '';
                    $return = 1;
                    
                    try {
                        // Логируем начало выполнения
                        error_log("DevPanel: Starting command execution: $cmd");
                        
                        // Выполняем команду и захватываем весь вывод
                        // Используем proc_open для лучшего контроля над выводом
                        $descriptorspec = [
                            0 => ['pipe', 'r'],
                            1 => ['pipe', 'w'],
                            2 => ['pipe', 'w']
                        ];
                        $process = proc_open($cmd, $descriptorspec, $pipes);
                        
                        if (is_resource($process)) {
                            fclose($pipes[0]);
                            
                            // Таймаут для чтения потоков
                            stream_set_timeout($pipes[1], 600);
                            stream_set_timeout($pipes[2], 600);
                            
                            // Читаем весь вывод (ждём завершения процесса)
                            $stdout = stream_get_contents($pipes[1]);
                            $stderr = stream_get_contents($pipes[2]);
                            
                            // Закрываем потоки ДО proc_close — после proc_close ресурсы уже невалидны
                            if (is_resource($pipes[1])) {
                                fclose($pipes[1]);
                                $pipes[1] = null;
                            }
                            if (is_resource($pipes[2])) {
                                fclose($pipes[2]);
                                $pipes[2] = null;
                            }
                            
                            $return = proc_close($process);
                            $fullOutput = $stdout . ($stderr !== '' ? "\n" . $stderr : '');
                            $output = explode("\n", $fullOutput);
                            
                            error_log("DevPanel: Command completed with exit code: $return, output length: " . strlen($fullOutput));
                        } else {
                            error_log("DevPanel: proc_open failed, falling back to exec");
                            // Fallback на exec если proc_open не сработал
                            exec($cmd, $output, $return);
                            $fullOutput = implode("\n", $output);
                        }
                    } catch (Exception $e) {
                        error_log("DevPanel: Exception during command execution: " . $e->getMessage());
                        $fullOutput = "Ошибка выполнения команды: " . $e->getMessage();
                        $output = [$fullOutput];
                        $return = 1;
                    }
                    
                    $executionTime = round(microtime(true) - $startTime, 2);
                    // Формируем сообщение об ошибке из первых строк вывода
                    $errorMessage = "Ошибка при создании проекта";
                    if ($return !== 0 && !empty($output)) {
                        $errorLines = array_filter(array_slice($output, -10), function($line) {
                            return trim($line) !== '' && 
                                   (stripos($line, 'error') !== false || 
                                    stripos($line, 'failed') !== false ||
                                    stripos($line, 'unable') !== false);
                        });
                        if (!empty($errorLines)) {
                            $errorMessage = "Ошибка: " . implode("; ", array_slice($errorLines, 0, 3));
                        } else {
                            $errorMessage = "Ошибка: " . trim(end($output));
                        }
                    }
                    
                    $actionResult = [
                        'type' => $return === 0 ? 'success' : 'error',
                        'message' => $return === 0
                            ? "Проект {$projectName} создан успешно!"
                            : $errorMessage,
                        'output' => $fullOutput,
                        'output_lines' => $output,
                        'command' => $cmd,
                        'execution_time' => $executionTime,
                        'exit_code' => $return
                    ];
                    logDevpanelAction($stateDir, 'create', $return === 0 ? 'success' : 'error', [
                        'project' => $projectName,
                        'preset' => $preset,
                        'bitrix_type' => $preset === 'bitrix' ? $bitrixType : null,
                        'core_id' => $coreId ?: null,
                        'command' => $cmd,
                        'output_head' => array_slice($output, 0, 15),
                        'execution_time' => $executionTime,
                    ]);
                    
                    if ($isAjax) {
                        // Убеждаемся, что заголовки отправлены правильно
                        if (!headers_sent()) {
                            header('Content-Type: application/json; charset=utf-8');
                            header('Cache-Control: no-cache, must-revalidate');
                        }
                        
                        // Логируем ответ
                        error_log("DevPanel: Sending JSON response, type: " . $actionResult['type']);
                        
                        $jsonResponse = json_encode($actionResult, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
                        if ($jsonResponse === false) {
                            error_log("DevPanel: JSON encode error: " . json_last_error_msg());
                            $actionResult['type'] = 'error';
                            $actionResult['message'] = 'Ошибка формирования ответа: ' . json_last_error_msg();
                            $jsonResponse = json_encode($actionResult, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
                        }
                        
                        echo $jsonResponse;
                        exit;
                    }
                    
                    if ($return === 0) {
                        header('Location: ' . $_SERVER['PHP_SELF']);
                        exit;
                    }
                } else {
                    $errorMsg = 'CLI hostctl не найден в контейнере devpanel (/scripts/hostctl.sh)';
                    logDevpanelAction($stateDir, 'create', 'error', [
                        'project' => $projectName,
                        'reason' => 'hostctl_not_found',
                    ]);
                    $actionResult = ['type' => 'error', 'message' => $errorMsg];
                    if ($isAjax) {
                        header('Content-Type: application/json; charset=utf-8');
                        echo json_encode($actionResult, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
                        exit;
                    }
                }
            } else {
                $errorMsg = 'Некорректное имя проекта (только латинские буквы, цифры, дефисы и точки)';
                logDevpanelAction($stateDir, 'create', 'error', [
                    'project' => $projectName,
                    'reason' => 'invalid_project_name',
                ]);
                $actionResult = ['type' => 'error', 'message' => $errorMsg];
                if ($isAjax) {
                    header('Content-Type: application/json; charset=utf-8');
                    echo json_encode($actionResult, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
                    exit;
                }
            }
            break;

        case 'create_status':
            if (!$isAjax) {
                $actionResult = ['type' => 'error', 'message' => 'create_status доступен только через AJAX'];
                break;
            }

            $jobId = trim((string)($_POST['job_id'] ?? ''));
            $offset = (int)($_POST['offset'] ?? 0);
            if (!preg_match('/^create_[A-Za-z0-9_.-]+$/', $jobId)) {
                if (!headers_sent()) {
                    header('Content-Type: application/json; charset=utf-8');
                }
                echo json_encode([
                    'type' => 'error',
                    'status' => 'done',
                    'message' => 'Некорректный идентификатор задачи',
                    'job_id' => $jobId,
                    'offset' => 0,
                    'chunk' => '',
                ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
                exit;
            }

            $jobsDir = $stateDir !== '' ? rtrim((string)$stateDir, '/') . '/devpanel-jobs' : '';
            if ($jobsDir === '' || !is_dir($jobsDir)) {
                if (!headers_sent()) {
                    header('Content-Type: application/json; charset=utf-8');
                }
                echo json_encode([
                    'type' => 'error',
                    'status' => 'done',
                    'message' => 'Каталог фоновых задач недоступен',
                    'job_id' => $jobId,
                    'offset' => 0,
                    'chunk' => '',
                ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
                exit;
            }
            $jobMetaFile = $jobsDir . '/' . $jobId . '.json';
            $jobLogFile = $jobsDir . '/' . $jobId . '.log';
            $jobExitFile = $jobsDir . '/' . $jobId . '.exit';

            if (!is_file($jobMetaFile)) {
                if (!headers_sent()) {
                    header('Content-Type: application/json; charset=utf-8');
                }
                echo json_encode([
                    'type' => 'error',
                    'status' => 'done',
                    'message' => 'Задача не найдена или уже удалена',
                    'job_id' => $jobId,
                    'offset' => 0,
                    'chunk' => '',
                ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
                exit;
            }

            $chunk = '';
            $newOffset = max(0, $offset);
            if (is_file($jobLogFile)) {
                $size = (int)@filesize($jobLogFile);
                if ($size < 0) $size = 0;
                if ($newOffset > $size) {
                    $newOffset = $size;
                }

                $fh = @fopen($jobLogFile, 'rb');
                if (is_resource($fh)) {
                    @fseek($fh, $newOffset);
                    $part = stream_get_contents($fh);
                    if ($part !== false) {
                        $chunk = $part;
                        $newOffset += strlen($part);
                    }
                    @fclose($fh);
                }
            }

            $isDone = is_file($jobExitFile);
            $exitCode = null;
            $type = 'pending';
            $status = 'running';
            $message = 'Выполняется создание проекта...';
            $errorKind = null;

            if ($isDone) {
                $status = 'done';
                $exitRaw = trim((string)@file_get_contents($jobExitFile));
                $exitCode = is_numeric($exitRaw) ? (int)$exitRaw : 1;
                $type = $exitCode === 0 ? 'success' : 'error';
                $meta = json_decode((string)@file_get_contents($jobMetaFile), true);
                $projectName = is_array($meta) ? trim((string)($meta['project'] ?? '')) : '';
                $errorKind = 'generic';
                if ($exitCode === 0) {
                    $message = 'Проект создан успешно';
                } else {
                    $logText = is_file($jobLogFile) ? (string)@file_get_contents($jobLogFile) : '';
                    $errorKind = detectCreateErrorKind($logText);
                    if ($errorKind === 'conflict') {
                        $message = $projectName !== ''
                            ? "Хост {$projectName} уже существует. Укажите другое имя или удалите существующий хост."
                            : 'Хост с таким именем уже существует. Укажите другое имя или удалите существующий хост.';
                    } elseif ($errorKind === 'foreign_suffix') {
                        $message = 'Хост использует суффикс, отличный от активной зоны. Введите короткое имя или домен в формате <name>.' . $domainSuffix . ' (см. DOMAIN_SUFFIX в infra/.env.global)';
                    } elseif ($errorKind === 'invalid_host') {
                        $message = 'Некорректное имя хоста. Допустимо: короткое имя или полный домен в формате <name>.' . $domainSuffix;
                    } elseif ($errorKind === 'infra') {
                        $message = 'Ошибка инфраструктуры Docker при создании хоста. Проверьте доступ Docker и настройки shared paths.';
                    } else {
                        $message = 'Создание проекта завершилось с ошибкой';
                    }
                }

                if (is_array($meta) && empty($meta['result_logged'])) {
                    $headLines = [];
                    if (is_file($jobLogFile)) {
                        $allLines = @file($jobLogFile, FILE_IGNORE_NEW_LINES);
                        if (is_array($allLines)) {
                            $headLines = array_slice($allLines, 0, 25);
                        }
                    }
                    logDevpanelAction($stateDir, 'create', $exitCode === 0 ? 'success' : 'error', [
                        'project' => $meta['project'] ?? null,
                        'job_id' => $jobId,
                        'command' => $meta['command'] ?? null,
                        'output_head' => $headLines,
                        'exit_code' => $exitCode,
                        'finished_at' => gmdate('Y-m-d\TH:i:s\Z'),
                    ]);
                    $meta['result_logged'] = true;
                    $meta['status'] = $exitCode === 0 ? 'success' : 'error';
                    $meta['exit_code'] = $exitCode;
                    $meta['finished_at'] = gmdate('Y-m-d\TH:i:s\Z');
                    @file_put_contents($jobMetaFile, json_encode($meta, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
                }
            }

            if (!headers_sent()) {
                header('Content-Type: application/json; charset=utf-8');
                header('Cache-Control: no-cache, must-revalidate');
            }
            echo json_encode([
                'type' => $type,
                'status' => $status,
                'message' => $message,
                'job_id' => $jobId,
                'offset' => $newOffset,
                'chunk' => $chunk,
                'exit_code' => $exitCode,
                'error_kind' => $errorKind,
            ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            exit;
            
        case 'delete':
            $projectName = trim($_POST['project_name'] ?? '');
            if (!empty($projectName) && preg_match('/^[a-z0-9\-\.]+$/i', $projectName) && file_exists($hostctlScript)) {
                $cmd = 'bash ' . escapeshellarg($hostctlScript) . ' delete ' . escapeshellarg($projectName) . ' --yes 2>&1';
                $output = [];
                exec($cmd, $output, $return);
                $outputHead = array_slice($output, 0, 15);
                $outputText = implode("\n", $outputHead);
                if ($return === 0) {
                    $actionResult = [
                        'type' => 'success',
                        'message' => "Проект {$projectName} удален",
                    ];
                    logDevpanelAction($stateDir, 'delete', 'success', [
                        'project' => $projectName,
                        'command' => $cmd,
                        'output_head' => $outputHead,
                    ]);
                    header('Location: ' . $_SERVER['PHP_SELF']);
                    exit;
                }

                if (preg_match('/\bnot found\b/i', $outputText)) {
                    $actionResult = [
                        'type' => 'warning',
                        'message' => "Проект {$projectName} уже отсутствует. Повторное удаление не требуется.",
                    ];
                    logDevpanelAction($stateDir, 'delete', 'warning', [
                        'project' => $projectName,
                        'reason' => 'already_missing',
                        'command' => $cmd,
                        'output_head' => $outputHead,
                    ]);
                } elseif (preg_match('/Error\[delete_guard\]/i', $outputText)) {
                    $guardMessage = "Удаление core-хоста заблокировано: сначала удалите связанные link-хосты.";
                    if (preg_match('/Error\[delete_guard\]:\s*(.+)$/mi', $outputText, $m) && trim((string)$m[1]) !== '') {
                        $guardMessage = trim((string)$m[1]);
                    }
                    $actionResult = [
                        'type' => 'warning',
                        'message' => $guardMessage,
                    ];
                    logDevpanelAction($stateDir, 'delete', 'warning', [
                        'project' => $projectName,
                        'reason' => 'delete_guard',
                        'command' => $cmd,
                        'output_head' => $outputHead,
                    ]);
                } else {
                    $actionResult = [
                        'type' => 'error',
                        'message' => "Ошибка: " . $outputText,
                    ];
                    logDevpanelAction($stateDir, 'delete', 'error', [
                        'project' => $projectName,
                        'command' => $cmd,
                        'output_head' => $outputHead,
                    ]);
                }
            } elseif (!file_exists($hostctlScript)) {
                logDevpanelAction($stateDir, 'delete', 'error', [
                    'project' => $projectName,
                    'reason' => 'hostctl_not_found',
                ]);
                $actionResult = ['type' => 'error', 'message' => 'CLI hostctl не найден в контейнере devpanel (/scripts/hostctl.sh)'];
            }
            break;
            
        case 'start':
        case 'stop':
        case 'restart':
            $projectName = trim($_POST['project_name'] ?? '');
            if (empty($projectName) || !preg_match('/^[a-z0-9\-\.]+$/i', $projectName)) {
                $actionResult = ['type' => 'error', 'message' => 'Некорректное имя проекта.'];
                break;
            }
            if (!file_exists($hostctlScript)) {
                $actionResult = ['type' => 'error', 'message' => 'CLI hostctl не найден в контейнере devpanel (/scripts/hostctl.sh)'];
                break;
            }

            if ($action === 'restart') {
                $cmd = '(bash ' . escapeshellarg($hostctlScript) . ' stop ' . escapeshellarg($projectName)
                    . ' && bash ' . escapeshellarg($hostctlScript) . ' start ' . escapeshellarg($projectName) . ') 2>&1';
            } else {
                $cmd = 'bash ' . escapeshellarg($hostctlScript) . ' ' . escapeshellarg($action) . ' ' . escapeshellarg($projectName) . ' 2>&1';
            }

            $output = [];
            exec($cmd, $output, $return);

            if ($return !== 0) {
                $actionResult = [
                    'type' => 'error',
                    'message' => 'Ошибка выполнения команды: ' . implode("\n", array_slice($output, 0, 15))
                ];
                logDevpanelAction($stateDir, $action, 'error', [
                    'project' => $projectName,
                    'command' => $cmd,
                    'output_head' => array_slice($output, 0, 15),
                ]);
            } else {
                logDevpanelAction($stateDir, $action, 'success', [
                    'project' => $projectName,
                    'command' => $cmd,
                ]);
                header('Location: ' . $_SERVER['PHP_SELF']);
                exit;
            }
            break;

    }
}

// Если GET запрос для логов
if (isset($_GET['action']) && $_GET['action'] === 'logs' && isset($_GET['project'])) {
    $projectName = $_GET['project'];
    $projectPath = $projectsDir . '/' . $projectName;
    $composeFile = $projectPath . '/docker-compose.yml';
    if (is_dir($projectPath) && file_exists($composeFile)) {
        header('Content-Type: text/plain; charset=utf-8');
        $output = [];
        exec('docker compose -f ' . escapeshellarg($composeFile) . ' logs --tail=200 2>&1', $output, $return);
        echo implode("\n", $output);
        exit;
    }
}

// Получаем список всех доменов проектов для конфига /etc/hosts
$hostsDomains = [];
foreach ($projects as $project) {
    $hostsDomains[] = $project['name'];
}
// Добавляем домены инфраструктуры (активная зона)
foreach ($serviceDomains as $svc => $domain) {
    $hostsDomains[] = $domain;
}
$hostsDomains = array_unique($hostsDomains);
sort($hostsDomains);

// Сравнение требуемых записей hosts с вставленным содержимым (п. 2.1)
$hostsCompare = null; // [ ['domain' => ..., 'line' => ..., 'present' => bool ], ... ]
$hostsPasted = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['hosts_compare']) && isset($_POST['hosts_content'])) {
    $hostsPasted = trim($_POST['hosts_content']);
    $presentHostnames = [];
    if ($hostsPasted !== '') {
        $lines = preg_split('/\r\n|\r|\n/', $hostsPasted);
        foreach ($lines as $line) {
            $line = trim($line);
            if ($line === '' || $line[0] === '#') continue;
            $parts = preg_split('/\s+/', $line, 2);
            if (count($parts) >= 2) {
                $hostname = trim($parts[1]);
                if ($hostname !== '') {
                    $presentHostnames[$hostname] = true;
                }
            }
        }
    }
    $hostsCompare = [];
    foreach ($hostsDomains as $domain) {
        $line = '127.0.0.1  ' . $domain;
        $hostsCompare[] = [
            'domain' => $domain,
            'line' => $line,
            'present' => isset($presentHostnames[$domain]),
        ];
    }
}

?>
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>DevPanel - Управление Docker проектами</title>
    <?php
    $vendorBase = __DIR__ . '/vendor';
    $useLocalAssets = is_file($vendorBase . '/coreui/coreui.min.css');
    $coreuiCss = $useLocalAssets ? 'vendor/coreui/coreui.min.css' : 'https://cdn.jsdelivr.net/npm/@coreui/coreui@5.3.0/dist/css/coreui.min.css';
    $iconsCss = $useLocalAssets ? 'vendor/bootstrap-icons/bootstrap-icons.css' : 'https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css';
    $bootstrapJs = $useLocalAssets ? 'vendor/bootstrap/bootstrap.bundle.min.js' : 'https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js';
    ?>
    <link href="<?= htmlspecialchars($coreuiCss) ?>" rel="stylesheet">
    <link rel="stylesheet" href="<?= htmlspecialchars($iconsCss) ?>">
    <style>
        :root {
            --primary-gradient: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            --card-shadow: 0 2px 8px rgba(0,0,0,0.1);
            --card-hover-shadow: 0 4px 12px rgba(0,0,0,0.15);
            --sidebar-width: 220px;
            --header-height: 56px;
        }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f5f7fa; margin: 0; }
        .app-header {
            position: fixed; top: 0; left: 0; right: 0; height: var(--header-height);
            background: #fff; border-bottom: 1px solid #e5e7eb; z-index: 1030;
            display: flex; align-items: center; justify-content: space-between; padding: 0 1rem;
            box-shadow: 0 1px 3px rgba(0,0,0,0.04);
        }
        .app-header-brand { font-weight: 600; font-size: 1rem; color: #1e293b; display: flex; align-items: center; gap: 0.5rem; }
        .header-status { display: flex; align-items: center; gap: 0.75rem; font-size: 0.8rem; flex-wrap: wrap; }
        .header-status a { text-decoration: none; color: inherit; }
        .header-status-badge { display: inline-flex; align-items: center; gap: 0.35rem; padding: 0.25rem 0.5rem; border-radius: 0.375rem; }
        .header-status-badge.infrastructure { background: #f1f5f9; color: #475569; }
        .header-status-badge.infrastructure.all-up { background: #dcfce7; color: #166534; }
        .header-status-badge.infrastructure.partial { background: #fef3c7; color: #92400e; }
        .header-status-badge.projects { background: #f1f5f9; color: #475569; }
        .header-status-badge.projects.all-up { background: #dcfce7; color: #166534; }
        .header-status-badge.projects.partial { background: #fef3c7; color: #92400e; }
        .layout-wrapper { display: flex; min-height: 100vh; padding-top: var(--header-height); }
        .sidebar {
            position: fixed;
            top: var(--header-height);
            left: 0;
            bottom: 0;
            width: var(--sidebar-width);
            min-width: var(--sidebar-width);
            background: linear-gradient(180deg, #1e293b 0%, #0f172a 100%);
            color: rgba(255,255,255,0.9);
            z-index: 1020;
            transition: margin-left 0.2s, width 0.2s;
            border-right: 1px solid rgba(255,255,255,0.06);
            display: flex;
            flex-direction: column;
            overflow: hidden;
        }
        .main { margin-left: var(--sidebar-width); }
        .sidebar-nav {
            display: flex;
            flex-direction: column;
            padding: 0.15rem 0.45rem;
            flex: 1;
            min-height: 0;
            overflow-y: auto;
        }
        .sidebar-nav .nav-link {
            flex: 0 0 auto;
            display: flex; align-items: center; gap: 0.4rem;
            padding: 0.18rem 0.5rem;
            font-size: 0.8rem;
            font-weight: 500;
            color: rgba(255,255,255,0.75);
            text-decoration: none;
            border-radius: 0.2rem;
            margin-bottom: 0.02rem;
            transition: all 0.15s ease;
        }
        .sidebar-nav .nav-link:hover { background: rgba(255,255,255,0.08); color: #fff; }
        .sidebar-nav .nav-link.active { background: rgba(255,255,255,0.12); color: #fff; border-left: 3px solid rgba(255,255,255,0.5); padding-left: calc(0.5rem - 3px); }
        .sidebar-nav .nav-link i { font-size: 0.9rem; opacity: 0.9; width: 1.1em; text-align: center; }
        .main { flex: 1; display: flex; flex-direction: column; min-width: 0; }
        .main-header {
            background: #fff;
            border-bottom: 1px solid #e5e7eb;
            padding: 0.75rem 1.25rem;
            display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 0.5rem;
        }
        .main-header h2 { margin: 0; font-size: 1.1rem; font-weight: 600; color: #1e293b; }
        .main-content { flex: 1; padding: 1.25rem; }
        .resource-card, .project-card { transition: transform 0.2s, box-shadow 0.2s; }
        .resource-card:hover, .project-card:hover { transform: translateY(-2px); box-shadow: var(--card-hover-shadow); }
        .status-badge { font-size: 0.75rem; padding: 0.25rem 0.75rem; }
        .container-item { font-family: 'Monaco','Menlo',monospace; font-size: 0.85rem; padding: 0.5rem; background: #f8f9fa; border-radius: 4px; margin-bottom: 0.5rem; }
        .btn-action { margin: 0; white-space: nowrap; }
        .btn-action-group { display: flex; flex-wrap: wrap; align-items: center; gap: 0.35rem; }
        .btn-action-group .btn, .btn-action-group a.btn { display: inline-flex; align-items: center; min-height: 31px; }
        .modal-header { background: var(--primary-gradient); color: white; }
        @media (max-width: 992px) {
            .main { margin-left: 0; }
            .sidebar { margin-left: calc(-1 * var(--sidebar-width)); position: fixed; top: var(--header-height); left: 0; bottom: 0; z-index: 1040; }
            .sidebar.show { margin-left: 0; box-shadow: 4px 0 15px rgba(0,0,0,0.15); }
            .sidebar-backdrop { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.4); z-index: 1039; }
            .sidebar-backdrop.show { display: block; }
            .sidebar-toggle { display: block !important; }
        }
        .sidebar-toggle { display: none; }
    </style>
</head>
<body>
    <header class="app-header">
        <div class="d-flex align-items-center">
            <button class="btn btn-link text-body sidebar-toggle d-lg-none p-0 me-2" type="button" onclick="var s=document.getElementById('sidebar');var b=document.getElementById('sidebarBackdrop');s.classList.toggle('show');b.classList.toggle('show');" aria-label="Меню"><i class="bi bi-list fs-4"></i></button>
            <div class="app-header-brand"><i class="bi bi-boxes"></i> PillatDevPanel</div>
        </div>
        <div class="header-status d-none d-sm-flex">
            <?php
            $baseHref = htmlspecialchars($_SERVER['SCRIPT_NAME'] ?? '/index.php');
            $infraUp = 0; $infraTotal = 7;
            if ($infraStatus && !$infraStatus['error']) {
                foreach ($infraStatus['services'] as $s) { if ($s['status'] === 'Up') $infraUp++; }
            }
            $infraClass = ($infraStatus && $infraStatus['error']) ? '' : ($infraUp === $infraTotal ? 'all-up' : ($infraUp > 0 ? 'partial' : ''));
            $projTotal = $headerProjectSummary['total'];
            $projRun = $headerProjectSummary['running'];
            $projClass = $projTotal === 0 ? '' : ($projRun === $projTotal ? 'all-up' : ($projRun > 0 ? 'partial' : ''));
            ?>
            <a href="<?= $baseHref ?>?page=infra" class="header-status-badge infrastructure <?= $infraClass ?>" title="Сервисы инфраструктуры">
                <i class="bi bi-server"></i>
                <span><?= $infraStatus && $infraStatus['error'] ? '—' : ($infraUp . '/' . $infraTotal) ?></span>
            </a>
            <a href="<?= $baseHref ?>?page=projects" class="header-status-badge projects <?= $projClass ?>" title="Проекты">
                <i class="bi bi-folder"></i>
                <span><?= $projTotal === 0 ? '0' : ($projRun . '/' . $projTotal) ?></span>
            </a>
        </div>
    </header>
    <div class="layout-wrapper">
        <aside class="sidebar" id="sidebar">
            <nav class="sidebar-nav" role="navigation">
                <?php $baseHref = htmlspecialchars($_SERVER['SCRIPT_NAME'] ?? '/index.php'); ?>
                <a class="nav-link <?= $currentPage === 'projects' ? 'active' : '' ?>" href="<?= $baseHref ?>?page=projects"><i class="bi bi-folder"></i> Проекты</a>
                <a class="nav-link <?= $currentPage === 'infra' ? 'active' : '' ?>" href="<?= $baseHref ?>?page=infra"><i class="bi bi-server"></i> Инфраструктура</a>
                <a class="nav-link <?= $currentPage === 'hosts' ? 'active' : '' ?>" href="<?= $baseHref ?>?page=hosts"><i class="bi bi-file-earmark-text"></i> Hosts</a>
                <a class="nav-link <?= $currentPage === 'help' ? 'active' : '' ?>" href="<?= $baseHref ?>?page=help"><i class="bi bi-question-circle"></i> Справка</a>
            </nav>
        </aside>
        <div class="sidebar-backdrop d-lg-none" id="sidebarBackdrop" onclick="document.getElementById('sidebar').classList.remove('show'); this.classList.remove('show');"></div>
        <main class="main">
            <header class="main-header">
                <h2>
                    <?php
                    $pageTitles = ['projects' => 'Проекты', 'infra' => 'Инфраструктура', 'hosts' => 'Конфигурация Hosts', 'help' => 'Справка'];
                    echo htmlspecialchars($pageTitles[$currentPage] ?? 'DevPanel');
                    ?>
                </h2>
            </header>
            <div class="main-content">

        <?php if ($domainZoneError): ?>
            <div class="alert alert-warning alert-dismissible fade show" role="alert">
                <i class="bi bi-exclamation-triangle"></i> <?= htmlspecialchars($domainZoneError) ?>
                <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
            </div>
        <?php endif; ?>
        <?php if ($actionResult): ?>
            <?php
                $alertType = (string)($actionResult['type'] ?? 'error');
                $alertClass = 'danger';
                if ($alertType === 'success') {
                    $alertClass = 'success';
                } elseif ($alertType === 'warning') {
                    $alertClass = 'warning';
                }
            ?>
            <div class="alert alert-<?= $alertClass ?> alert-dismissible fade show" role="alert">
                <?= htmlspecialchars($actionResult['message']) ?>
                <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
            </div>
        <?php endif; ?>

        <?php if ($currentPage === 'infra'): ?>
        <?php
            $infraServiceMeta = [
                'traefik' => ['icon' => 'bi-speedometer2', 'color' => 'primary', 'desc' => 'Мониторинг роутинга', 'path' => '/dashboard/'],
                'adminer' => ['icon' => 'bi-database', 'color' => 'success', 'desc' => 'Управление БД', 'path' => ''],
                'redis' => ['icon' => 'bi-memory', 'color' => 'danger', 'desc' => 'Кэш и сессии', 'path' => ''],
                'loki' => ['icon' => 'bi-journal-text', 'color' => 'info', 'desc' => 'Хранилище логов', 'path' => ''],
                'promtail' => ['icon' => 'bi-collection', 'color' => 'info', 'desc' => 'Сбор логов', 'path' => ''],
                'grafana' => ['icon' => 'bi-graph-up', 'color' => 'info', 'desc' => 'Логи и метрики', 'path' => ''],
                'devpanel' => ['icon' => 'bi-boxes', 'color' => 'secondary', 'desc' => 'Эта панель', 'path' => '', 'linkKey' => 'docker'],
            ];
        ?>
        <!-- Страница: Инфраструктура -->
        <div class="row mb-4">
            <div class="col-12">
                <h3 class="mb-3"><i class="bi bi-activity"></i> Сервисы</h3>
                <?php if ($infraStatus && $infraStatus['error']): ?>
                <div class="alert alert-warning">
                    <i class="bi bi-exclamation-triangle"></i> Данные недоступны
                    <span class="text-muted small ms-2">(проверено: <?= htmlspecialchars($infraStatus['lastCheck']) ?>)</span>
                </div>
                <?php elseif ($infraStatus && !$infraStatus['error']): ?>
                <p class="text-muted small mb-3">Проверено: <?= htmlspecialchars($infraStatus['lastCheck']) ?></p>
                <div class="row">
                    <?php foreach ($infraStatus['services'] as $key => $s):
                        $meta = $infraServiceMeta[$key] ?? ['icon' => 'bi-box', 'color' => 'secondary', 'desc' => '', 'path' => ''];
                        $linkKey = $meta['linkKey'] ?? $key;
                        $isUp = ($s['status'] === 'Up');
                        $hasLink = isset($serviceDomains[$linkKey]);
                        $url = $hasLink ? 'https://' . $serviceDomains[$linkKey] . ($meta['path'] ?? '') : '#';
                    ?>
                    <div class="col-md-6 col-lg-3 mb-3">
                        <div class="card resource-card h-100">
                            <div class="card-body">
                                <div class="d-flex align-items-center justify-content-between mb-2">
                                    <h6 class="card-title mb-0"><i class="bi <?= $meta['icon'] ?> text-<?= $meta['color'] ?>"></i> <?= htmlspecialchars($s['name']) ?></h6>
                                    <span class="badge bg-<?= $isUp ? 'success' : 'secondary' ?>"><?= htmlspecialchars($s['status']) ?></span>
                                </div>
                                <p class="text-muted small mb-2"><?= htmlspecialchars($meta['desc']) ?></p>
                                <?php if ($key === 'devpanel'): ?>
                                <a href="<?= htmlspecialchars($url) ?>" class="btn btn-sm btn-outline-<?= $meta['color'] ?> w-100"><i class="bi bi-arrow-clockwise"></i> Обновить</a>
                                <?php elseif ($isUp && $hasLink): ?>
                                <a href="<?= htmlspecialchars($url) ?>" target="_blank" class="btn btn-sm btn-<?= $meta['color'] ?> w-100"><i class="bi bi-box-arrow-up-right"></i> Открыть</a>
                                <?php else: ?>
                                <span class="btn btn-sm btn-outline-secondary w-100 disabled opacity-75" style="pointer-events:none" title="Сервис остановлен"><i class="bi bi-box-arrow-up-right"></i> Открыть</span>
                                <?php endif; ?>
                            </div>
                        </div>
                    </div>
                    <?php endforeach; ?>
                </div>
                <?php endif; ?>
            </div>
        </div>
        <?php elseif ($currentPage === 'hosts'): ?>
        <!-- Страница: Hosts -->
        <div class="row">
            <div class="col-12">
                <div class="card">
                    <div class="card-header bg-info text-white">
                        <h5 class="mb-0"><i class="bi bi-file-earmark-text"></i> Конфигурация /etc/hosts</h5>
                    </div>
                    <div class="card-body">
                        <p class="text-muted mb-3">
                            <i class="bi bi-info-circle"></i> Скопируйте следующий конфиг и добавьте в файл <code>/etc/hosts</code> на вашем компьютере:
                        </p>
                        <div class="mb-3">
                            <button class="btn btn-sm btn-outline-primary" onclick="copyHostsConfig()">
                                <i class="bi bi-clipboard"></i> Копировать конфиг
                            </button>
                        </div>
                        <?php if ($hostsCompare !== null): ?>
                        <div class="mb-3">
                            <strong>Сравнение с вашим hosts:</strong> отсутствующие записи подсвечены <span class="text-danger">красным</span>, присутствующие — <span class="text-success">зелёным</span>.
                        </div>
                        <pre class="bg-light p-3 rounded border" id="hostsConfig" style="max-height: 400px; overflow-y: auto;"><code># Docker Development Infrastructure
<?php foreach ($hostsCompare as $item): ?><span class="text-<?= $item['present'] ? 'success' : 'danger' ?>">127.0.0.1  <?= htmlspecialchars($item['domain']) ?></span>
<?php endforeach; ?></code></pre>
                        <?php else: ?>
                        <pre class="bg-light p-3 rounded border" id="hostsConfig" style="max-height: 400px; overflow-y: auto;"><code># Docker Development Infrastructure
<?php foreach ($hostsDomains as $domain): ?>127.0.0.1 <?= htmlspecialchars($domain) ?>

<?php endforeach; ?></code></pre>
                        <?php endif; ?>
                        <hr class="my-4">
                        <p class="text-muted mb-2">
                            <i class="bi bi-arrow-left-right"></i> Вставьте содержимое вашего файла <code>/etc/hosts</code> и нажмите «Сравнить», чтобы подсветить отсутствующие записи красным.
                        </p>
                        <form method="POST" action="<?= $baseHref ?>?page=hosts" class="mb-3">
                            <input type="hidden" name="hosts_compare" value="1">
                            <textarea class="form-control font-monospace mb-2" name="hosts_content" rows="6" placeholder="# Вставьте сюда содержимое /etc/hosts (Linux/macOS) или C:\Windows\System32\drivers\etc\hosts (Windows)"><?= htmlspecialchars($hostsPasted) ?></textarea>
                            <button type="submit" class="btn btn-sm btn-outline-info">
                                <i class="bi bi-check2-square"></i> Сравнить
                            </button>
                        </form>
                        <div class="alert alert-warning mt-3 mb-0">
                            <i class="bi bi-exclamation-triangle"></i> <strong>Важно:</strong> Для редактирования <code>/etc/hosts</code> потребуются права администратора (sudo).
                        </div>
                    </div>
                </div>
            </div>
        </div>
        <?php elseif ($currentPage === 'help'): ?>
        <!-- Страница: Справка -->
        <div class="row">
            <div class="col-12 col-lg-8">
                <div class="card mb-4">
                    <div class="card-header"><h5 class="mb-0"><i class="bi bi-info-circle"></i> О DevPanel</h5></div>
                    <div class="card-body">
                        <p>DevPanel — веб-интерфейс для управления Docker-проектами и локальной инфраструктурой.</p>
                        <p class="mb-0">Доменная зона задаётся в <code>infra/.env.global</code> (ключ <code>DOMAIN_SUFFIX</code>). Все сервисы доступны по доменам <code>*.<?= htmlspecialchars($domainSuffix) ?></code>.</p>
                    </div>
                </div>
                <div class="card">
                    <div class="card-header"><h5 class="mb-0"><i class="bi bi-book"></i> Документация</h5></div>
                    <div class="card-body">
                        <p class="mb-0">См. <code>README.md</code> и <code>infra/docs/DOMAIN_SUFFIX-MIGRATION.md</code> в репозитории.</p>
                    </div>
                </div>
            </div>
        </div>
        <?php else: ?>
        <!-- Страница: Проекты -->
        <div class="row mb-4" id="create-form">
            <div class="col-12">
                <div class="card">
                    <div class="card-header bg-primary text-white">
                        <h5 class="mb-0"><i class="bi bi-plus-circle"></i> Создать новый проект</h5>
                    </div>
                    <div class="card-body">
                        <form method="POST" action="" id="createProjectForm">
                            <input type="hidden" name="action" value="create">
                            <div class="row">
                                <div class="col-md-4 mb-3">
                                    <label class="form-label" id="projectNameLabel">Имя проекта (домен)</label>
                                    <div class="input-group">
                                        <input type="text" class="form-control" name="project_name" 
                                               id="projectNameInput"
                                               placeholder="my-project" required 
                                               pattern="[a-z0-9\-\.]+" 
                                               title="Короткое имя или полный домен в зоне <?= htmlspecialchars($domainSuffix) ?>"
                                               data-domain-suffix="<?= htmlspecialchars($domainSuffix) ?>">
                                        <span class="input-group-text" id="projectNameZoneAddon">.<?= htmlspecialchars($domainSuffix) ?></span>
                                    </div>
                                </div>
                                <div class="col-md-3 mb-3">
                                    <label class="form-label">PHP версия</label>
                                    <select class="form-select" name="php_version" required>
                                        <option value="8.2" selected>8.2</option>
                                        <option value="8.1">8.1</option>
                                        <option value="8.3">8.3</option>
                                        <option value="8.4">8.4</option>
                                        <option value="7.4">7.4</option>
                                    </select>
                                </div>
                                <div class="col-md-2 mb-3">
                                    <label class="form-label">База данных</label>
                                    <select class="form-select" name="db_type" required>
                                        <option value="mysql" selected>MySQL</option>
                                        <option value="postgres">PostgreSQL</option>
                                    </select>
                                </div>
                                <div class="col-md-2 mb-3">
                                    <label class="form-label">Пресет</label>
                                    <select class="form-select" name="preset" id="presetSelect" required>
                                        <option value="php" selected>Чистый PHP</option>
                                        <option value="bitrix">Bitrix</option>
                                        <option value="laravel">Laravel</option>
                                        <option value="wordpress">WordPress</option>
                                        <option value="static">Static/SPA</option>
                                    </select>
                                </div>
                                <div class="col-12 col-md-auto mb-3 d-flex align-items-end">
                                    <button type="submit" class="btn btn-primary text-nowrap">
                                        <i class="bi bi-plus-lg"></i> Создать
                                    </button>
                                </div>
                            </div>
                            <div class="row" id="bitrixFields" style="display:none;">
                                <div class="col-md-3 mb-3">
                                    <label class="form-label">Bitrix type</label>
                                    <select class="form-select" name="bitrix_type" id="bitrixTypeSelect">
                                        <option value="kernel" selected>kernel (core)</option>
                                        <option value="ext_kernel">ext_kernel (core, без HTTP)</option>
                                        <option value="link">link (привязка к core)</option>
                                    </select>
                                </div>
                                <div class="col-md-5 mb-3" id="coreIdFieldWrapper" style="display:none;">
                                    <label class="form-label" id="coreIdLabel">Core ID</label>
                                    <input type="text"
                                           class="form-control"
                                           name="core_id"
                                           id="coreIdInput"
                                           placeholder="core-main-shop"
                                           pattern="[a-z0-9][a-z0-9-]{1,62}"
                                           title="Только a-z, 0-9, дефис; длина 2..63">
                                    <div class="form-text" id="coreIdHelp">
                                        Укажите существующий core_id, к которому будет привязан link-хост.
                                    </div>
                                </div>
                            </div>
                        </form>
                    </div>
                </div>
            </div>
        </div>

        <!-- Список проектов -->
        <div class="row">
            <div class="col-12">
                <h3 class="mb-3"><i class="bi bi-folder"></i> Проекты (<?= count($projects) ?>)</h3>
                
                <?php if (empty($projects)): ?>
                    <div class="alert alert-info">
                        <i class="bi bi-info-circle"></i> Проекты не найдены. Создайте новый проект выше.
                    </div>
                <?php else: ?>
                    <?php foreach ($projects as $project): 
                        $containers = getProjectContainers($project['name']);
                        $metadata = getProjectMetadata($project['path'], $hostsRegistry, $bitrixCoreByOwner, $bitrixBindingByHost);
                        $runningCount = 0;
                        foreach ($containers as $container) {
                            if (strpos($container['status'], 'Up') === 0) {
                                $runningCount++;
                            }
                        }
                        $isRunning = $runningCount > 0;
                        $domain = $project['name'];
                        $linkedHosts = [];
                        $deleteBlocked = false;
                        if (!empty($metadata['bitrix_type']) && in_array($metadata['bitrix_type'], ['kernel', 'ext_kernel'], true) && !empty($metadata['core_id'])) {
                            $linkedHosts = $bitrixLinksByCore[$metadata['core_id']] ?? [];
                            $linkedHosts = array_values(array_filter($linkedHosts, function($hostName) use ($project) {
                                return $hostName !== $project['name'];
                            }));
                            $deleteBlocked = count($linkedHosts) > 0;
                        }
                    ?>
                        <div class="card project-card mb-3">
                            <div class="card-body">
                            <div class="d-flex justify-content-between align-items-start mb-2">
                                <div class="flex-grow-1">
                                    <h4 class="mb-1 d-flex align-items-center gap-1 flex-wrap">
                                        <i class="bi bi-folder-fill text-primary"></i>
                                        <?= htmlspecialchars($project['name']) ?>
                                        <?php if (empty($metadata['bitrix_type']) || $metadata['bitrix_type'] !== 'ext_kernel'): ?>
                                        <a href="https://<?= htmlspecialchars($domain) ?>" target="_blank" class="btn btn-sm btn-outline-primary py-0 px-1" title="Открыть сайт"><i class="bi bi-box-arrow-up-right"></i></a>
                                        <?php endif; ?>
                                        <?php if ($domainSuffix && devpanel_is_legacy_host($project['name'], $domainSuffix)): ?>
                                            <span class="text-muted small" title="Хост вне активной зоны">(legacy)</span>
                                        <?php endif; ?>
                                    </h4>
                                    <p class="text-muted small mb-0" style="font-weight: normal;">
                                        <?php
                                        $params = [];
                                        if (!empty($metadata['php_version'])) $params[] = 'PHP ' . $metadata['php_version'];
                                        if (!empty($metadata['db_type'])) $params[] = 'БД ' . $metadata['db_type'];
                                        if (!empty($metadata['preset'])) $params[] = 'Пресет ' . $metadata['preset'];
                                        if (!empty($metadata['bitrix_type'])) $params[] = 'Bitrix ' . $metadata['bitrix_type'];
                                        if (!empty($metadata['core_id'])) $params[] = 'Core ' . $metadata['core_id'];
                                        echo implode(' · ', $params);
                                        ?>
                                    </p>
                                    <p class="text-muted small mb-0">
                                        <i class="bi bi-server"></i> Контейнеров: <?= count($containers) ?> (<span class="text-success"><?= $runningCount ?> запущено</span>)
                                    </p>
                                </div>
                                <span class="badge bg-<?= $isRunning ? 'success' : 'secondary' ?> status-badge flex-shrink-0">
                                    <?= $isRunning ? '<i class="bi bi-play-circle"></i> Запущен' : '<i class="bi bi-stop-circle"></i> Остановлен' ?>
                                </span>
                            </div>

                            <!-- Дополнительные параметры: хост БД, env -->
                            <div class="mb-3">
                                <button type="button" class="btn btn-sm btn-outline-primary" data-bs-toggle="collapse" 
                                        data-bs-target="#meta-<?= md5($project['name']) ?>" aria-expanded="false">Хост БД, env</button>
                                <div class="collapse mt-1" id="meta-<?= md5($project['name']) ?>">
                                    <div class="p-2 text-muted" style="font-size: 0.85rem; font-weight: normal;">
                                        <?php if (!empty($metadata['db_host'])): ?>
                                            <span>Хост БД: <?= htmlspecialchars($metadata['db_host']) ?></span>
                                        <?php endif; ?>
                                        <?php if ($deleteBlocked): ?>
                                            <div class="alert alert-warning py-2 mb-2 mt-2">
                                                <i class="bi bi-shield-exclamation"></i>
                                                Удаление этого core-хоста заблокировано: активные link-хосты <?= htmlspecialchars(implode(', ', $linkedHosts)) ?>.
                                            </div>
                                        <?php endif; ?>
                                        <?php if (!empty($metadata['env'])): ?>
                                            <div class="mt-2">
                                                <span>Переменные окружения:</span>
                                                <pre class="mb-0 mt-1 p-2 bg-light rounded border" style="font-size: 0.8rem; max-height: 200px; overflow-y: auto;"><?php foreach ($metadata['env'] as $k => $v) { echo htmlspecialchars($k . ' = ' . $v) . "\n"; } ?></pre>
                                            </div>
                                        <?php endif; ?>
                                    </div>
                                </div>
                            </div>

                            <?php if (!empty($containers)): ?>
                                <div class="mb-3">
                                    <strong class="small">Контейнеры:</strong>
                                    <?php foreach ($containers as $container): ?>
                                        <div class="container-item mb-2">
                                            <div class="d-flex justify-content-between align-items-center mb-2">
                                                <span><code><?= htmlspecialchars($container['name']) ?></code></span>
                                                <span class="badge bg-<?= strpos($container['status'], 'Up') === 0 ? 'success' : 'secondary' ?>">
                                                    <?= strpos($container['status'], 'Up') === 0 ? 'Up' : 'Down' ?>
                                                </span>
                                            </div>
                                            <?php if (!empty($container['config'])): ?>
                                                <button class="btn btn-sm btn-outline-info mt-1" type="button" data-bs-toggle="collapse" 
                                                        data-bs-target="#config-<?= md5($container['name']) ?>" 
                                                        aria-expanded="false" aria-controls="config-<?= md5($container['name']) ?>">
                                                    <i class="bi bi-gear"></i> Конфигурация
                                                </button>
                                                <div class="collapse mt-2" id="config-<?= md5($container['name']) ?>">
                                                    <div class="card card-body bg-light p-2" style="font-size: 0.85rem;">
                                                        <div class="mb-2">
                                                            <strong>Image:</strong> <code><?= htmlspecialchars($container['config']['image']) ?></code>
                                                        </div>
                                                        <?php if (!empty($container['config']['ports'])): ?>
                                                            <div class="mb-2">
                                                                <strong>Ports:</strong>
                                                                <ul class="mb-0 ps-3">
                                                                    <?php foreach ($container['config']['ports'] as $port): ?>
                                                                        <li><code><?= htmlspecialchars($port) ?></code></li>
                                                                    <?php endforeach; ?>
                                                                </ul>
                                                            </div>
                                                        <?php endif; ?>
                                                        <?php if (!empty($container['config']['volumes'])): ?>
                                                            <div class="mb-2">
                                                                <strong>Volumes:</strong>
                                                                <ul class="mb-0 ps-3">
                                                                    <?php foreach (array_slice($container['config']['volumes'], 0, 5) as $vol): ?>
                                                                        <li><code style="font-size: 0.8rem;"><?= htmlspecialchars($vol) ?></code></li>
                                                                    <?php endforeach; ?>
                                                                    <?php if (count($container['config']['volumes']) > 5): ?>
                                                                        <li><em>... и еще <?= count($container['config']['volumes']) - 5 ?></em></li>
                                                                    <?php endif; ?>
                                                                </ul>
                                                            </div>
                                                        <?php endif; ?>
                                                        <?php if (!empty($container['config']['networks'])): ?>
                                                            <div class="mb-2">
                                                                <strong>Networks:</strong>
                                                                <ul class="mb-0 ps-3">
                                                                    <?php foreach ($container['config']['networks'] as $net): ?>
                                                                        <li><code><?= htmlspecialchars($net) ?></code></li>
                                                                    <?php endforeach; ?>
                                                                </ul>
                                                            </div>
                                                        <?php endif; ?>
                                                        <?php if (!empty($container['config']['environment'])): ?>
                                                            <div class="mb-2">
                                                                <strong>Environment:</strong>
                                                                <ul class="mb-0 ps-3">
                                                                    <?php foreach (array_slice($container['config']['environment'], 0, 3) as $env): ?>
                                                                        <li><code style="font-size: 0.8rem;"><?= htmlspecialchars($env) ?></code></li>
                                                                    <?php endforeach; ?>
                                                                    <?php if (count($container['config']['environment']) > 3): ?>
                                                                        <li><em>... и еще <?= count($container['config']['environment']) - 3 ?></em></li>
                                                                    <?php endif; ?>
                                                                </ul>
                                                            </div>
                                                        <?php endif; ?>
                                                        <?php if (!empty($container['config']['working_dir'])): ?>
                                                            <div class="mb-2">
                                                                <strong>Working Dir:</strong> <code><?= htmlspecialchars($container['config']['working_dir']) ?></code>
                                                            </div>
                                                        <?php endif; ?>
                                                    </div>
                                                </div>
                                            <?php endif; ?>
                                        </div>
                                    <?php endforeach; ?>
                                </div>
                            <?php endif; ?>

                            <div class="btn-action-group">
                                <form method="POST" action="" style="display: inline;">
                                    <input type="hidden" name="action" value="<?= $isRunning ? 'stop' : 'start' ?>">
                                    <input type="hidden" name="project_name" value="<?= htmlspecialchars($project['name']) ?>">
                                    <button type="submit" class="btn btn-sm btn-<?= $isRunning ? 'warning' : 'success' ?> btn-action">
                                        <i class="bi bi-<?= $isRunning ? 'stop' : 'play' ?>-fill"></i> 
                                        <?= $isRunning ? 'Остановить' : 'Запустить' ?>
                                    </button>
                                </form>
                                
                                <form method="POST" action="" style="display: inline;">
                                    <input type="hidden" name="action" value="restart">
                                    <input type="hidden" name="project_name" value="<?= htmlspecialchars($project['name']) ?>">
                                    <button type="submit" class="btn btn-sm btn-secondary btn-action">
                                        <i class="bi bi-arrow-clockwise"></i> Перезапустить
                                    </button>
                                </form>
                                
                                <a href="?action=logs&project=<?= urlencode($project['name']) ?>" 
                                   target="_blank" 
                                   class="btn btn-sm btn-info btn-action">
                                    <i class="bi bi-file-text"></i> Логи
                                </a>
                                
                                <button type="button" 
                                        class="btn btn-sm btn-danger btn-action <?= $deleteBlocked ? 'disabled' : '' ?>" 
                                        data-bs-toggle="modal" 
                                        data-bs-target="#deleteModal<?= md5($project['name']) ?>"
                                        <?= $deleteBlocked ? 'disabled aria-disabled="true" title="Удаление core заблокировано: есть активные link-хосты"' : '' ?>>
                                    <i class="bi bi-trash"></i> Удалить
                                </button>
                            </div>
                            <?php if ($deleteBlocked): ?>
                                <div class="text-warning small mt-2">
                                    <i class="bi bi-shield-lock"></i>
                                    Удаление недоступно: сначала удалите link-хосты, привязанные к core `<?= htmlspecialchars($metadata['core_id']) ?>`.
                                </div>
                            <?php endif; ?>
                            </div>
                        </div>

                        <!-- Modal для удаления -->
                        <div class="modal fade" id="deleteModal<?= md5($project['name']) ?>" tabindex="-1">
                            <div class="modal-dialog">
                                <div class="modal-content">
                                    <div class="modal-header">
                                        <h5 class="modal-title">Удаление проекта</h5>
                                        <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
                                    </div>
                                    <div class="modal-body">
                                        <p>Вы уверены, что хотите удалить проект <strong><?= htmlspecialchars($project['name']) ?></strong>?</p>
                                        <p class="text-danger small"><i class="bi bi-exclamation-triangle"></i> Это действие нельзя отменить. Все файлы проекта будут удалены.</p>
                                        <?php if ($deleteBlocked): ?>
                                            <div class="alert alert-warning mb-0">
                                                <i class="bi bi-shield-exclamation"></i>
                                                Удаление core-хоста заблокировано, пока существуют link-хосты: <?= htmlspecialchars(implode(', ', $linkedHosts)) ?>.
                                            </div>
                                        <?php endif; ?>
                                    </div>
                                    <div class="modal-footer">
                                        <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Отмена</button>
                                        <?php if (!$deleteBlocked): ?>
                                            <form method="POST" action="" style="display: inline;">
                                                <input type="hidden" name="action" value="delete">
                                                <input type="hidden" name="project_name" value="<?= htmlspecialchars($project['name']) ?>">
                                                <button type="submit" class="btn btn-danger">
                                                    <i class="bi bi-trash"></i> Удалить
                                                </button>
                                            </form>
                                        <?php endif; ?>
                                    </div>
                                </div>
                            </div>
                        </div>
                    <?php endforeach; ?>
                <?php endif; ?>
            </div>
        </div>
        <?php endif; ?>
            </div>
        </main>
    </div>

    <script src="<?= htmlspecialchars($bootstrapJs) ?>"></script>
    <script>
        function copyHostsConfig() {
            const config = document.getElementById('hostsConfig').textContent;
            navigator.clipboard.writeText(config).then(function() {
                const btn = event.target.closest('button');
                const originalText = btn.innerHTML;
                btn.innerHTML = '<i class="bi bi-check"></i> Скопировано!';
                btn.classList.remove('btn-outline-primary');
                btn.classList.add('btn-success');
                setTimeout(function() {
                    btn.innerHTML = originalText;
                    btn.classList.remove('btn-success');
                    btn.classList.add('btn-outline-primary');
                }, 2000);
            });
        }

        function toggleBitrixFields() {
            const preset = document.getElementById('presetSelect');
            const bitrixFields = document.getElementById('bitrixFields');
            if (!preset || !bitrixFields) return;

            if (preset.value === 'bitrix') {
                bitrixFields.style.display = '';
            } else {
                bitrixFields.style.display = 'none';
                // Сбрасываем поля Bitrix при смене пресета
                const coreIdInput = document.getElementById('coreIdInput');
                const bitrixTypeSelect = document.getElementById('bitrixTypeSelect');
                if (coreIdInput) coreIdInput.value = '';
                if (bitrixTypeSelect) bitrixTypeSelect.value = 'kernel';
            }
            updateCoreFieldState();
        }

        function updateCoreFieldState() {
            const bitrixType = document.getElementById('bitrixTypeSelect');
            const coreIdInput = document.getElementById('coreIdInput');
            const coreIdLabel = document.getElementById('coreIdLabel');
            const coreIdHelp = document.getElementById('coreIdHelp');
            const coreIdFieldWrapper = document.getElementById('coreIdFieldWrapper');
            const preset = document.getElementById('presetSelect');
            const projectNameLabel = document.getElementById('projectNameLabel');
            const projectNameInput = document.getElementById('projectNameInput');
            const projectNameZoneAddon = document.getElementById('projectNameZoneAddon');
            
            if (!bitrixType || !coreIdInput || !coreIdLabel || !coreIdHelp || !preset || !coreIdFieldWrapper) return;

            const active = preset.value === 'bitrix';
            const isLink = bitrixType.value === 'link';
            const isKernel = bitrixType.value === 'kernel';
            const isExtKernel = bitrixType.value === 'ext_kernel';

            // Показываем/скрываем поле core_id только для link
            if (active && isLink) {
                coreIdFieldWrapper.style.display = '';
                coreIdInput.required = true;
                coreIdLabel.textContent = 'Core ID (обязательно для link)';
                coreIdHelp.textContent = 'Укажите существующий core_id, к которому будет привязан link-хост.';
            } else {
                coreIdFieldWrapper.style.display = 'none';
                coreIdInput.required = false;
                coreIdInput.value = ''; // Очищаем значение при скрытии
            }

            // Обновляем label, placeholder и зону для project_name в зависимости от типа Bitrix
            // ext_kernel: core_id без доменной зоны (папка ядра)
            // kernel/link: домен с зоной из конфига (инпут + статичный суффикс .pillat)
            if (projectNameLabel && projectNameInput) {
                const suffix = projectNameInput.getAttribute('data-domain-suffix') || 'loc';
                if (active && isExtKernel) {
                    projectNameLabel.textContent = 'Имя проекта (core_id)';
                    projectNameInput.placeholder = 'core-main-shop';
                    projectNameInput.pattern = '[a-z0-9][a-z0-9-]{1,62}';
                    projectNameInput.title = 'core_id: буквы, цифры, дефисы; 2–63 символа';
                    if (projectNameZoneAddon) projectNameZoneAddon.style.display = 'none';
                    if (projectNameInput.value && projectNameInput.value.includes('.')) {
                        projectNameInput.value = '';
                    }
                } else {
                    projectNameLabel.textContent = 'Имя проекта (домен)';
                    projectNameInput.placeholder = 'my-project';
                    projectNameInput.pattern = '[a-z0-9\\-\\.]+';
                    projectNameInput.title = 'Короткое имя или полный домен в зоне ' + suffix;
                    if (projectNameZoneAddon) projectNameZoneAddon.style.display = '';
                }
            }
        }

        document.addEventListener('DOMContentLoaded', function() {
            const preset = document.getElementById('presetSelect');
            const bitrixType = document.getElementById('bitrixTypeSelect');
            if (preset) preset.addEventListener('change', toggleBitrixFields);
            if (bitrixType) bitrixType.addEventListener('change', updateCoreFieldState);
            toggleBitrixFields();

            // AJAX отправка формы создания проекта
            const createForm = document.getElementById('createProjectForm');
            if (createForm) {
                createForm.addEventListener('submit', function(e) {
                    e.preventDefault();
                    
                    const formData = new FormData(createForm);
                    formData.append('ajax', '1');
                    const submitButton = createForm.querySelector('button[type="submit"]');
                    const submitButtonHtml = submitButton ? submitButton.innerHTML : '';
                    if (submitButton) {
                        submitButton.disabled = true;
                        submitButton.innerHTML = '<span class="spinner-border spinner-border-sm me-1" role="status" aria-hidden="true"></span>Создание...';
                    }
                    
                    const modal = new bootstrap.Modal(document.getElementById('createProjectModal'));
                    const modalBody = document.getElementById('createProjectModalBody');
                    const modalTitle = document.getElementById('createProjectModalTitle');
                    const logOutput = document.getElementById('createProjectLogOutput');
                    const logContainer = document.getElementById('createProjectLogContainer');
                    const spinner = document.getElementById('createProjectSpinner');
                    const successAlert = document.getElementById('createProjectSuccessAlert');
                    const errorAlert = document.getElementById('createProjectErrorAlert');
                    const restoreSubmitButton = () => {
                        if (!submitButton) return;
                        submitButton.disabled = false;
                        submitButton.innerHTML = submitButtonHtml;
                    };
                    const setCreateErrorAlertKind = (kind) => {
                        errorAlert.classList.remove('alert-danger', 'alert-warning');
                        if (kind === 'warning') {
                            errorAlert.classList.add('alert-warning');
                        } else {
                            errorAlert.classList.add('alert-danger');
                        }
                    };
                    
                    // Сброс состояния модального окна
                    modalTitle.innerHTML = 'Создание проекта...';
                    logOutput.innerHTML = '';
                    logContainer.style.display = 'none';
                    spinner.style.display = 'block';
                    successAlert.style.display = 'none';
                    errorAlert.style.display = 'none';
                    setCreateErrorAlertKind('error');
                    
                    // Удаляем старую информацию о времени выполнения, если есть
                    const oldTimeInfo = modalBody.querySelector('.execution-time-info');
                    if (oldTimeInfo) {
                        oldTimeInfo.remove();
                    }
                    
                    modal.show();
                    
                    const renderLogChunk = (chunk, append = true) => {
                        if (!chunk || !chunk.trim()) return;
                        logContainer.style.display = 'block';
                        const lines = chunk.split('\n');
                        const html = lines.map(line => {
                            const escaped = escapeHtml(line);
                            if (line.trim() === '') return '<div class="log-line-empty">&nbsp;</div>';
                            const lowerLine = line.toLowerCase();
                            if (lowerLine.includes('error') || lowerLine.includes('failed') || lowerLine.includes('unable')) {
                                return '<div class="log-line log-line-error">' + escaped + '</div>';
                            }
                            if (lowerLine.includes('success') || lowerLine.includes('started') || lowerLine.includes('created') || lowerLine.includes('✅')) {
                                return '<div class="log-line log-line-success">' + escaped + '</div>';
                            }
                            if (lowerLine.includes('building') || lowerLine.includes('pulling') || lowerLine.includes('creating')) {
                                return '<div class="log-line log-line-info">' + escaped + '</div>';
                            }
                            return '<div class="log-line">' + escaped + '</div>';
                        }).join('');

                        if (append) {
                            logOutput.innerHTML += html;
                        } else {
                            logOutput.innerHTML = html;
                        }
                        logOutput.scrollTop = logOutput.scrollHeight;
                    };

                    const parseJsonResponse = (response) => {
                        if (!response.ok) {
                            throw new Error('HTTP error! status: ' + response.status);
                        }
                        const contentType = response.headers.get('content-type');
                        if (!contentType || !contentType.includes('application/json')) {
                            return response.text().then(text => {
                                console.error('Non-JSON response:', text);
                                throw new Error('Server returned non-JSON response: ' + text.substring(0, 100));
                            });
                        }
                        return response.json();
                    };

                    const requestUrl = window.location.pathname || '/index.php';
                    const toUrlEncoded = (formDataLike) => {
                        const params = new URLSearchParams();
                        for (const [key, value] of formDataLike.entries()) {
                            params.append(key, value);
                        }
                        return params;
                    };

                    const createPayload = toUrlEncoded(formData);

                    fetch(requestUrl, {
                        method: 'POST',
                        headers: {
                            'X-Requested-With': 'XMLHttpRequest',
                            'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'
                        },
                        body: createPayload.toString()
                    })
                    .then(parseJsonResponse)
                    .then(data => {
                        console.log('Create start response:', data);

                        // Новый async-поток: задача ушла в фон, начинаем опрос статуса
                        if (data.type === 'pending' && data.job_id) {
                            modalTitle.innerHTML = '<i class="bi bi-hourglass-split text-primary"></i> Создание проекта...';
                            successAlert.style.display = 'none';
                            errorAlert.style.display = 'none';
                            logContainer.style.display = 'block';
                            renderLogChunk(data.chunk || '', false);

                            let offset = Number.isFinite(Number(data.offset)) ? Number(data.offset) : 0;
                            const jobId = data.job_id;
                            const pollStartedAt = Date.now();
                            const pollTimeoutMs = 12 * 60 * 1000; // 12 минут

                            const pollStatus = () => {
                                if (Date.now() - pollStartedAt > pollTimeoutMs) {
                                    spinner.style.display = 'none';
                                    modalTitle.innerHTML = '<i class="bi bi-x-circle text-danger"></i> Таймаут ожидания';
                                    setCreateErrorAlertKind('error');
                                    errorAlert.style.display = 'block';
                                    errorAlert.querySelector('.alert-message').textContent = 'Превышено время ожидания статуса фоновой задачи.';
                                    restoreSubmitButton();
                                    return;
                                }

                                const statusData = new URLSearchParams();
                                statusData.append('action', 'create_status');
                                statusData.append('ajax', '1');
                                statusData.append('job_id', jobId);
                                statusData.append('offset', String(offset));

                                fetch(requestUrl, {
                                    method: 'POST',
                                    headers: {
                                        'X-Requested-With': 'XMLHttpRequest',
                                        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'
                                    },
                                    body: statusData.toString()
                                })
                                .then(parseJsonResponse)
                                .then(statusResp => {
                                    if (typeof statusResp.offset !== 'undefined') {
                                        const nextOffset = Number(statusResp.offset);
                                        if (Number.isFinite(nextOffset) && nextOffset >= 0) {
                                            offset = nextOffset;
                                        }
                                    }
                                    if (statusResp.chunk) {
                                        renderLogChunk(statusResp.chunk, true);
                                    }

                                    if (statusResp.status === 'running') {
                                        setTimeout(pollStatus, 1200);
                                        return;
                                    }

                                    spinner.style.display = 'none';
                                    if (statusResp.type === 'success') {
                                        modalTitle.innerHTML = '<i class="bi bi-check-circle text-success"></i> Проект создан успешно!';
                                        successAlert.style.display = 'block';
                                        successAlert.querySelector('.alert-message').textContent = statusResp.message || 'Готово';
                                        setTimeout(() => {
                                            window.location.reload();
                                        }, 2000);
                                    } else {
                                        if (statusResp.error_kind === 'conflict') {
                                            modalTitle.innerHTML = '<i class="bi bi-exclamation-circle text-warning"></i> Имя уже занято';
                                            setCreateErrorAlertKind('warning');
                                        } else if (statusResp.error_kind === 'foreign_suffix' || statusResp.error_kind === 'invalid_host') {
                                            modalTitle.innerHTML = '<i class="bi bi-exclamation-triangle text-warning"></i> Некорректный домен';
                                            setCreateErrorAlertKind('warning');
                                        } else {
                                            modalTitle.innerHTML = '<i class="bi bi-x-circle text-danger"></i> Ошибка создания проекта';
                                            setCreateErrorAlertKind('error');
                                        }
                                        errorAlert.style.display = 'block';
                                        errorAlert.querySelector('.alert-message').textContent = statusResp.message || 'Создание завершилось с ошибкой';
                                        restoreSubmitButton();
                                    }
                                })
                                .catch(error => {
                                    console.error('Status fetch error:', error);
                                    spinner.style.display = 'none';
                                    modalTitle.innerHTML = '<i class="bi bi-x-circle text-danger"></i> Ошибка запроса';
                                    setCreateErrorAlertKind('error');
                                    errorAlert.style.display = 'block';
                                    errorAlert.querySelector('.alert-message').textContent = 'Ошибка при получении статуса: ' + error.message;
                                    logContainer.style.display = 'block';
                                    renderLogChunk('Ошибка получения статуса: ' + error.message, true);
                                    restoreSubmitButton();
                                });
                            };

                            setTimeout(pollStatus, 500);
                            return;
                        }

                        // Fallback для старого sync-ответа
                        spinner.style.display = 'none';
                        if (data.output && data.output.trim()) {
                            renderLogChunk(data.output, false);
                        }
                        if (data.type === 'success') {
                            modalTitle.innerHTML = '<i class="bi bi-check-circle text-success"></i> Проект создан успешно!';
                            successAlert.style.display = 'block';
                            successAlert.querySelector('.alert-message').textContent = data.message;
                            setTimeout(() => {
                                window.location.reload();
                            }, 3000);
                        } else {
                            modalTitle.innerHTML = '<i class="bi bi-x-circle text-danger"></i> Ошибка создания проекта';
                            setCreateErrorAlertKind('error');
                            errorAlert.style.display = 'block';
                            errorAlert.querySelector('.alert-message').textContent = data.message;
                            restoreSubmitButton();
                        }
                        if (data.execution_time) {
                            const timeInfo = document.createElement('div');
                            timeInfo.className = 'text-muted small mt-2 execution-time-info';
                            timeInfo.textContent = 'Время выполнения: ' + data.execution_time + ' сек.';
                            modalBody.appendChild(timeInfo);
                        }
                    })
                    .catch(error => {
                        console.error('Fetch error:', error);
                        spinner.style.display = 'none';
                        modalTitle.innerHTML = '<i class="bi bi-x-circle text-danger"></i> Ошибка запроса';
                        setCreateErrorAlertKind('error');
                        errorAlert.style.display = 'block';
                        errorAlert.querySelector('.alert-message').textContent = 'Ошибка при отправке запроса: ' + error.message;
                        logContainer.style.display = 'block';
                        logOutput.innerHTML = '<div class="log-line log-line-error">Ошибка: ' + escapeHtml(error.message) + '</div>';
                        restoreSubmitButton();
                    });
                });
            }
        });
        
        function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }
    </script>
    
    <!-- Модальное окно создания проекта -->
    <div class="modal fade" id="createProjectModal" tabindex="-1" aria-labelledby="createProjectModalLabel" aria-hidden="true">
        <div class="modal-dialog modal-lg modal-dialog-scrollable">
            <div class="modal-content">
                <div class="modal-header">
                    <h5 class="modal-title" id="createProjectModalTitle">Создание проекта...</h5>
                    <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal" aria-label="Закрыть"></button>
                </div>
                <div class="modal-body" id="createProjectModalBody">
                    <div id="createProjectSpinner" class="text-center py-4">
                        <div class="spinner-border text-primary" role="status">
                            <span class="visually-hidden">Загрузка...</span>
                        </div>
                        <p class="mt-3 text-muted">Выполняется создание проекта...</p>
                    </div>
                    
                    <div id="createProjectSuccessAlert" class="alert alert-success" style="display:none;">
                        <i class="bi bi-check-circle"></i> <span class="alert-message"></span>
                    </div>
                    
                    <div id="createProjectErrorAlert" class="alert alert-danger" style="display:none;">
                        <i class="bi bi-exclamation-triangle"></i> <span class="alert-message"></span>
                    </div>
                    
                    <div id="createProjectLogContainer" style="display:none;">
                        <h6 class="mt-3 mb-2"><i class="bi bi-terminal"></i> Вывод команды:</h6>
                        <div id="createProjectLogOutput" class="log-output"></div>
                    </div>
                </div>
                <div class="modal-footer">
                    <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Закрыть</button>
                </div>
            </div>
        </div>
    </div>
    
    <style>
        .log-output {
            background: #1e1e1e;
            color: #d4d4d4;
            font-family: 'Monaco', 'Menlo', 'Courier New', monospace;
            font-size: 0.85rem;
            padding: 1rem;
            border-radius: 4px;
            max-height: 400px;
            overflow-y: auto;
            line-height: 1.5;
        }
        .log-line {
            padding: 2px 0;
            white-space: pre-wrap;
            word-break: break-word;
        }
        .log-line-empty {
            height: 1em;
        }
        .log-line-error {
            color: #f48771;
        }
        .log-line-success {
            color: #89d185;
        }
        .log-line-info {
            color: #4ec9b0;
        }
        .log-output::-webkit-scrollbar {
            width: 8px;
        }
        .log-output::-webkit-scrollbar-track {
            background: #2d2d2d;
        }
        .log-output::-webkit-scrollbar-thumb {
            background: #555;
            border-radius: 4px;
        }
        .log-output::-webkit-scrollbar-thumb:hover {
            background: #666;
        }
    </style>
</body>
</html>
