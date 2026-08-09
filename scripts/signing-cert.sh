#!/bin/bash
# Заводит постоянный сертификат, которым подписывается ClaudeWeek.
#
#   ./scripts/signing-cert.sh                     создать (или показать готовый)
#   ./scripts/signing-cert.sh --export copy.p12   создать и сохранить копию ключа
#   ./scripts/signing-cert.sh --import copy.p12   поставить готовый ключ (CI, вторая машина)
#   ./scripts/signing-cert.sh --show              что сейчас в связке ключей
#
# Зачем. Разрешение на чтение записи Keychain «Claude Code-credentials» macOS
# привязывает к designated requirement приложения. У ad-hoc подписи requirement
# это cdhash — хеш конкретного бинаря, свой у каждой сборки; поэтому нажатое
# «Всегда разрешать» переставало действовать после каждой пересборки, и диалог
# доступа к токену возвращался. Подпись своим сертификатом даёт requirement вида
# `identifier "com.greem4.claudeweek" and certificate leaf H"…"` — он одинаков
# для всех будущих сборок, и разрешение выдаётся один раз.
#
# Apple ID и Developer ID для этого не нужны: сертификат самоподписанный, и
# Gatekeeper он не убеждает — карантин со скачанного образа снимать по-прежнему
# руками. Он нужен ровно для стабильности requirement.
#
# Сертификат — единственное, что связывает разрешение с приложением: удалите его
# из связки ключей, и следующая сборка снова спросит доступ. Поэтому `--export`
# и хранение копии в надёжном месте — не лишняя предосторожность, а способ
# пережить переустановку системы.
set -euo pipefail

NAME="${CLAUDEWEEK_SIGN_IDENTITY:-ClaudeWeek Signing}"
KEYCHAIN="${CLAUDEWEEK_SIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
# 20 лет: срок жизни сертификата — это срок жизни выданного разрешения, и
# продлевать его человеку, который поставил виджет и забыл, будет нечем.
DAYS=7300

MODE="create"
EXPORT_TO=""
IMPORT_FROM=""
# Доверять сертификату обязательно: codesign отказывается брать identity, чья
# цепочка не сходится к доверенному корню — «no identity found» при вполне
# живом ключе в связке. user — доверие только для вашей учётной записи,
# system — для всей машины (нужен sudo; так делает CI на своём раннере).
TRUST="user"

while [ $# -gt 0 ]; do
    case "$1" in
        --export)
            EXPORT_TO="${2:-}"
            [ -n "$EXPORT_TO" ] || { echo "--export без пути" >&2; exit 2; }
            shift 2
            ;;
        --export=*) EXPORT_TO="${1#--export=}"; shift ;;
        --import)
            IMPORT_FROM="${2:-}"
            [ -n "$IMPORT_FROM" ] || { echo "--import без пути" >&2; exit 2; }
            MODE="import"
            shift 2
            ;;
        --import=*) IMPORT_FROM="${1#--import=}"; MODE="import"; shift ;;
        --keychain)
            KEYCHAIN="${2:-}"
            [ -n "$KEYCHAIN" ] || { echo "--keychain без пути" >&2; exit 2; }
            shift 2
            ;;
        --keychain=*) KEYCHAIN="${1#--keychain=}"; shift ;;
        --trust)
            TRUST="${2:-}"
            case "$TRUST" in
                user|system|none) ;;
                *) echo "--trust принимает user, system или none" >&2; exit 2 ;;
            esac
            shift 2
            ;;
        --trust=*) TRUST="${1#--trust=}"; shift ;;
        --show) MODE="show"; shift ;;
        -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "не знаю такого флага: $1" >&2; exit 2 ;;
    esac
done

# Хеш identity (SHA-1 сертификата) — то, чем подписывают. Имён-тёзок в связке
# может оказаться два, хеш один. Связку указываем явно: в CI она своя и в
# списке поиска может ещё не стоять.
identity_hash() {
    security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
        | awk -v name="\"$NAME\"" 'index($0, name) { print $2; exit }'
}

# Есть ключ, но identity не считается валидной — почти всегда это недостающее
# доверие, и различать эти два случая важно: во втором пересоздавать нечего.
untrusted_hash() {
    security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
        | awk -v name="\"$NAME\"" 'index($0, name) { print $2; exit }'
}

report() {
    local hash="$1"
    echo "==> сертификат «${NAME}»"
    echo "    хеш identity: $hash"
    echo "    связка: $KEYCHAIN"
    echo
    echo "Дальше: ./scripts/install.sh — бандл подпишется этим сертификатом."
    echo "При первом запуске macOS ещё раз спросит доступ к записи Keychain"
    echo "«Claude Code-credentials» — нажмите «Всегда разрешать». Больше этот"
    echo "вопрос не вернётся: requirement подписи с этого момента не меняется."
}

if [ "$MODE" = "show" ]; then
    HASH="$(identity_hash || true)"
    if [ -n "$HASH" ]; then
        report "$HASH"
        exit 0
    fi
    UNTRUSTED="$(untrusted_hash || true)"
    if [ -n "$UNTRUSTED" ]; then
        echo "сертификат «${NAME}» в связке есть ($UNTRUSTED), но не доверен —" >&2
        echo "codesign такую identity не возьмёт; починить: $0 --trust $TRUST" >&2
        exit 1
    fi
    echo "сертификата «${NAME}» нет; создать: $0" >&2
    exit 1
fi

HASH="$(identity_hash || true)"
if [ -n "$HASH" ] && [ "$MODE" = "create" ]; then
    echo "==> сертификат уже есть — ничего не меняю"
    [ -n "$EXPORT_TO" ] && echo "!!  копию ключа отдаёт только создание;" \
        "выгрузить существующий — Keychain Access → Export"
    report "$HASH"
    exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claudeweek-cert.XXXXXX")"
# Приватный ключ живёт в этом каталоге ровно до конца скрипта: дальше он в
# связке ключей, а файлу на диске место только там, куда попросили (--export).
trap 'rm -rf "$WORK"' EXIT

P12="$WORK/cert.p12"
CRT="$WORK/cert.crt"
P12_PASSWORD="${P12_PASSWORD:-$(uuidgen)}"

if [ "$MODE" = "import" ]; then
    [ -f "$IMPORT_FROM" ] || { echo "не нашёл файл: $IMPORT_FROM" >&2; exit 1; }
    cp "$IMPORT_FROM" "$P12"
    echo "==> беру ключ из $IMPORT_FROM"
else
    echo "==> создаю самоподписанный сертификат «${NAME}»"
    # Системный LibreSSL, а не openssl из PATH: у OpenSSL 3 из Homebrew
    # pkcs12 по умолчанию пишет шифрование, которого Security.framework не
    # понимает, — импорт падает на «MAC verification failed».
    cat > "$WORK/req.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" \
        -config "$WORK/req.cnf" -keyout "$WORK/cert.key" -out "$CRT" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$WORK/cert.key" -in "$CRT" \
        -name "$NAME" -out "$P12" -passout pass:"$P12_PASSWORD" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
fi

if [ ! -f "$CRT" ]; then
    /usr/bin/openssl pkcs12 -in "$P12" -passin pass:"$P12_PASSWORD" \
        -clcerts -nokeys -out "$CRT" 2>/dev/null \
        || { echo "не разобрал $IMPORT_FROM — не тот пароль? (P12_PASSWORD)" >&2; exit 1; }
fi

if [ -n "$EXPORT_TO" ]; then
    cp "$P12" "$EXPORT_TO"
    chmod 600 "$EXPORT_TO"
    echo "==> копия ключа: $EXPORT_TO"
    echo "    пароль: $P12_PASSWORD"
    echo "    этой парой ставится тот же сертификат на другую машину и в CI:"
    echo "    P12_PASSWORD=… ./scripts/signing-cert.sh --import <файл>"
fi

echo "==> кладу в связку ключей"
# -T /usr/bin/codesign, а не -A: доступ к ключу получает подписывающая утилита,
# а не любая программа, которой захочется им подписаться.
security import "$P12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign > /dev/null

# Разрешение на использование ключа. С паролем связки выдаётся сразу и молча —
# так работает CI; без пароля первое обращение codesign macOS сопроводит
# диалогом, где нужно нажать «Всегда разрешать» (тоже один раз).
if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" > /dev/null
    echo "    доступ codesign к ключу выдан"
else
    echo "    при первой подписи macOS спросит про доступ к ключу —"
    echo "    там «Всегда разрешать» (или задайте KEYCHAIN_PASSWORD и повторите)"
fi

# Отказ в диалоге доверия — не сбой скрипта, а решение человека, и звучать он
# должен по-человечески: `set -e` уронил бы всё на невнятном коде возврата.
case "$TRUST" in
    user)
        echo "==> доверяю сертификату для подписи кода (ваша учётная запись)"
        echo "    macOS спросит пароль — это он, ваш обычный пароль входа"
        if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CRT"; then
            echo >&2
            echo "доверие не выдано — без него codesign сертификат не возьмёт." >&2
            echo "Повторить: $0; на всю машину: $0 --trust system" >&2
            exit 1
        fi
        ;;
    system)
        echo "==> доверяю сертификату для подписи кода (вся машина, через sudo)"
        if ! sudo security add-trusted-cert -d -r trustRoot -p codeSign \
            -k /Library/Keychains/System.keychain "$CRT"; then
            echo "доверие на всю машину не выдано (sudo?)" >&2
            exit 1
        fi
        ;;
    none)
        echo "==> доверие не настраиваю (--trust none)"
        ;;
esac

HASH="$(identity_hash || true)"
if [ -z "$HASH" ]; then
    echo >&2
    echo "ключ в связке есть, но codesign его пока не берёт: доверие не встало." >&2
    echo "Ручной путь — Keychain Access: найдите «${NAME}», Get Info →" >&2
    echo "Trust → Code Signing → Always Trust. Или на всю машину:" >&2
    echo "  $0 --trust system" >&2
    exit 1
fi

report "$HASH"
