#!/bin/sh
set -eu

# ========== 기본값 ==========
IN_DIR_DEFAULT="/volume1/voicerec"
VENV_DEFAULT="/volume1/whisperenv"
SCRIPT_DIR="/volume1/script"
INTERVAL_DEFAULT="5"

# 옵션(기본 OFF)
SCAN_SUBDIRS_DEFAULT="0"   # 1이면 하위폴더까지 스캔
DONE_MOVE_DEFAULT="0"      # 1이면 처리 완료 mp3를 _done으로 이동

# 모델 기본값
MODEL_DEFAULT="small"
COMPUTE_DEFAULT="int8"
LANG_DEFAULT="ko"

# ========== 인자 ==========
IN_DIR="${1:-$IN_DIR_DEFAULT}"
VENV_DIR="${2:-$VENV_DEFAULT}"
INTERVAL_MIN="${3:-$INTERVAL_DEFAULT}"

PKG_TAG="VOICEREC_STT_V2"
PIPELINE="${SCRIPT_DIR}/voicerec_stt_pipeline.py"
CONFIG="${SCRIPT_DIR}/voicerec_stt_config.ini"
STATUS="${SCRIPT_DIR}/voicerec_stt_status.sh"
UNINSTALL="${SCRIPT_DIR}/voicerec_stt_uninstall.sh"

LOG_DIR="${IN_DIR}/_logs"
LOG_FILE="${LOG_DIR}/stt_pipeline.log"
CRON_LOG="/var/log/voicerec_stt.cron.log"
LOCK_FILE="/tmp/voicerec_stt.lock"

echo "[1/9] Precheck..."
python3 -V >/dev/null

mkdir -p "${IN_DIR}" "${SCRIPT_DIR}" "${LOG_DIR}"

echo "[2/9] ffmpeg check (mp3 requires it)..."
if command -v ffmpeg >/dev/null 2>&1; then
  echo "  - ffmpeg OK"
else
  echo "  - WARNING: ffmpeg not found. mp3 may fail. Install ffmpeg then re-run."
fi

echo "[3/9] Write config..."
cat > "${CONFIG}" <<EOF
[paths]
in_dir=${IN_DIR}

[stt]
model=${MODEL_DEFAULT}
compute_type=${COMPUTE_DEFAULT}
language=${LANG_DEFAULT}

[options]
scan_subdirs=${SCAN_SUBDIRS_DEFAULT}
done_move=${DONE_MOVE_DEFAULT}
done_dir=${IN_DIR}/_done

[schedule]
interval_minutes=${INTERVAL_MIN}
EOF

echo "[4/9] Install pipeline python..."
cat > "${PIPELINE}" <<'PY'
#!/usr/bin/env python3
import os, time, configparser
from pathlib import Path
from datetime import datetime
from typing import Optional
from faster_whisper import WhisperModel

def now(): return datetime.now().strftime("%Y-%m-%d %H:%M:%S")

def ensure_dir(p: Path): p.mkdir(parents=True, exist_ok=True)

def stable_file(p: Path, checks=3, interval=2) -> bool:
    last = -1
    for _ in range(checks):
        if not p.exists(): return False
        sz = p.stat().st_size
        if sz == last and sz > 0: return True
        last = sz
        time.sleep(interval)
    return p.exists() and p.stat().st_size == last and last > 0

def prefix3(stem: str, n=3) -> str:
    s = stem.strip().replace(" ", "").replace("_", "")
    return s[:n] if len(s) >= n else "UNK"

def load_cfg(path: str) -> configparser.ConfigParser:
    cfg = configparser.ConfigParser()
    cfg.read(path, encoding="utf-8")
    return cfg

_model: Optional[WhisperModel] = None

def get_model(model_name: str, compute_type: str, log_file: Path) -> WhisperModel:
    global _model
    if _model is None:
        with log_file.open("a", encoding="utf-8") as f:
            f.write(f"[{now()}] MODEL_LOAD {model_name} compute={compute_type}\n")
        _model = WhisperModel(model_name, compute_type=compute_type)
    return _model

def transcribe_to_txt(model: WhisperModel, mp3: Path, txt: Path, lang: str):
    segments, _info = model.transcribe(str(mp3), language=lang)
    with txt.open("w", encoding="utf-8") as f:
        for seg in segments:
            t = (seg.text or "").strip()
            if t: f.write(t + "\n")

def move_unique(src: Path, dst_dir: Path) -> Path:
    ensure_dir(dst_dir)
    dst = dst_dir / src.name
    if dst.exists():
        dst = dst_dir / f"{src.stem}_{int(time.time())}{src.suffix.lower()}"
    src.rename(dst)
    return dst

def iter_mp3(in_dir: Path, scan_subdirs: bool):
    if not scan_subdirs:
        for p in in_dir.iterdir():
            if p.is_file() and p.suffix.lower() == ".mp3" and not p.name.startswith(("_",".","_logs","_done")):
                yield p
        return
    # subdirs: 3레벨까지만 기본 스캔 (원하면 늘려도 됨)
    for p in in_dir.rglob("*.mp3"):
        # 관리폴더 제외
        if "/_logs/" in str(p) or "/_done/" in str(p): 
            continue
        if p.name.startswith(("_",".")): 
            continue
        yield p

def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--lock", default="/tmp/voicerec_stt.lock")
    args = ap.parse_args()

    # 중복 실행 방지(락 파일)
    lock = Path(args.lock)
    try:
        lock.write_text(str(os.getpid()), encoding="utf-8")
    except Exception:
        pass

    cfg = load_cfg(args.config)
    in_dir = Path(cfg.get("paths","in_dir", fallback="/volume1/voicerec"))
    model_name = cfg.get("stt","model", fallback="small")
    compute_type = cfg.get("stt","compute_type", fallback="int8")
    lang = cfg.get("stt","language", fallback="ko")

    scan_subdirs = cfg.get("options","scan_subdirs", fallback="0") == "1"
    done_move = cfg.get("options","done_move", fallback="0") == "1"
    done_dir = Path(cfg.get("options","done_dir", fallback=str(in_dir / "_done")))

    log_dir = in_dir / "_logs"
    ensure_dir(log_dir)
    log_file = log_dir / "stt_pipeline.log"

    if not in_dir.exists():
        with log_file.open("a", encoding="utf-8") as f:
            f.write(f"[{now()}] FATAL in_dir not found: {in_dir}\n")
        return

    model = get_model(model_name, compute_type, log_file)

    for p in iter_mp3(in_dir, scan_subdirs):
        # 파일 복사 중이면 스킵
        if not stable_file(p):
            with log_file.open("a", encoding="utf-8") as f:
                f.write(f"[{now()}] SKIP_NOT_STABLE {p}\n")
            continue

        who = prefix3(p.stem, 3)
        day = datetime.fromtimestamp(p.stat().st_mtime).strftime("%Y-%m-%d")

        # voicerec 내부에서 바로 분류
        dst_dir = in_dir / who / day
        src = p

        # 이미 분류된 경로면 이동 생략
        if dst_dir not in src.parents:
            try:
                src = move_unique(src, dst_dir)
            except Exception as e:
                with log_file.open("a", encoding="utf-8") as f:
                    f.write(f"[{now()}] MOVE_FAIL {p} err={e}\n")
                continue

        txt = src.with_suffix(".txt")
        if txt.exists() and txt.stat().st_size > 0:
            continue

        try:
            with log_file.open("a", encoding="utf-8") as f:
                f.write(f"[{now()}] STT_START {src}\n")
            transcribe_to_txt(model, src, txt, lang)
            with log_file.open("a", encoding="utf-8") as f:
                f.write(f"[{now()}] STT_OK {src} -> {txt}\n")
        except Exception as e:
            with log_file.open("a", encoding="utf-8") as f:
                f.write(f"[{now()}] STT_FAIL {src} err={e}\n")
            continue

        # 처리 완료 mp3를 _done으로 이동(옵션)
        if done_move:
            try:
                ensure_dir(done_dir)
                dst_done = done_dir / src.name
                if dst_done.exists():
                    dst_done = done_dir / f"{src.stem}_{int(time.time())}{src.suffix}"
                src.rename(dst_done)
                with log_file.open("a", encoding="utf-8") as f:
                    f.write(f"[{now()}] DONE_MOVE {dst_done}\n")
            except Exception as e:
                with log_file.open("a", encoding="utf-8") as f:
                    f.write(f"[{now()}] DONE_MOVE_FAIL {src} err={e}\n")

    try:
        lock.unlink(missing_ok=True)
    except Exception:
        pass

if __name__ == "__main__":
    main()
PY
chmod +x "${PIPELINE}"

echo "[5/9] Write status/uninstall helpers..."
cat > "${STATUS}" <<EOF
#!/bin/sh
set -eu
echo "== CONFIG =="; ls -lh "${CONFIG}" || true
echo "== CRON =="; grep "${PKG_TAG}" /etc/crontab || true
echo "== VENV =="; ls -lh "${VENV_DIR}" || true
echo "== LAST LOG =="; tail -n 50 "${LOG_FILE}" 2>/dev/null || true
echo "== CRON LOG =="; tail -n 50 "${CRON_LOG}" 2>/dev/null || true
EOF
chmod +x "${STATUS}"

cat > "${UNINSTALL}" <<EOF
#!/bin/sh
set -eu
sed -i "/${PKG_TAG}/d" /etc/crontab || true
synoservice --restart crond >/dev/null 2>&1 || true
echo "Removed cron. Files kept:"
echo "  ${PIPELINE}"
echo "  ${CONFIG}"
echo "  ${VENV_DIR}"
EOF
chmod +x "${UNINSTALL}"

echo "[6/9] Create/Update venv + install deps..."
if [ ! -d "${VENV_DIR}" ]; then
  python3 -m venv "${VENV_DIR}"
fi
. "${VENV_DIR}/bin/activate"

python -m pip install --upgrade pip setuptools wheel
pip install --only-binary=:all: "tokenizers==0.20.3" || pip install --only-binary=:all: "tokenizers==0.19.1"
pip install faster-whisper
python -c "from faster_whisper import WhisperModel; print('IMPORT_OK')"

echo "[7/9] Register cron every ${INTERVAL_MIN} minutes (idempotent)..."
CRON="/etc/crontab"
sed -i "/${PKG_TAG}/d" "${CRON}" || true
echo "*/${INTERVAL_MIN} * * * * root flock -n ${LOCK_FILE} sh -lc '. ${VENV_DIR}/bin/activate && python ${PIPELINE} --config ${CONFIG} --lock ${LOCK_FILE}' >> ${CRON_LOG} 2>&1 # ${PKG_TAG}" >> "${CRON}"
synoservice --restart crond >/dev/null 2>&1 || true

echo "[8/9] Done."
echo " - Install dir : ${IN_DIR}"
echo " - Config      : ${CONFIG}"
echo " - Pipeline    : ${PIPELINE}"
echo " - Status      : ${STATUS}"
echo " - Uninstall   : ${UNINSTALL}"
echo " - Cron log    : ${CRON_LOG}"
echo ""
echo "[9/9] Test now:"
echo "  . ${VENV_DIR}/bin/activate && python ${PIPELINE} --config ${CONFIG}"
