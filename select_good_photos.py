"""
从目录中筛选质量好且有人物的照片。
筛选条件:
  1. 有人脸（insightface 检测）
  2. 不模糊（OpenCV Laplacian 方差 > 阈值）
  3. 分辨率不低于设定值

用法:
    python select_good_photos.py --input D:\photos --output D:\good_photos
"""

import os
import shutil
import argparse
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor, as_completed
from multiprocessing import cpu_count

import cv2
import numpy as np
from PIL import Image

# insightface：pip install insightface
# 首次运行会自动下载模型（~/insightface/models/buffalo_l/）
try:
    import insightface
    from insightface.app import FaceAnalysis
except ImportError:
    print("请先安装: pip install insightface onnxruntime onnxruntime-gpu")
    exit(1)

IMAGE_EXTS = {'.jpg', '.jpeg', '.png', '.bmp', '.webp', '.heic', '.heif'}
LAPLACIAN_THRESHOLD = 150   # 低于此值认为模糊（可调，越大越严格）
MIN_WIDTH = 1920           # 最小宽度
MIN_HEIGHT = 1080          # 最小高度
FACE_CONFIDENCE = 0.7      # 人脸置信度阈值
MAX_WORKERS = cpu_count() // 2 or 1


def init_worker():
    """每个 worker 进程初始化自己的 face 模型（insightface 不支持多进程共享）"""
    global face_app
    face_app = FaceAnalysis(
        name='buffalo_l',
        root=os.path.expanduser('~/.insightface'),
        providers=['CPUExecutionProvider'],
    )
    face_app.prepare(ctx_id=0, det_size=(640, 640))


def check_photo(filepath: str, min_w=MIN_WIDTH, min_h=MIN_HEIGHT, blur_thresh=LAPLACIAN_THRESHOLD) -> dict:
    result = {"path": filepath, "ok": False, "reason": "", "faces": 0}
    ext = Path(filepath).suffix.lower()
    if ext not in IMAGE_EXTS:
        result["reason"] = "unsupported_ext"
        return result

    try:
        img = cv2.imread(filepath)
        if img is None:
            result["reason"] = "unreadable"
            return result

        h, w = img.shape[:2]
        if w < min_w or h < min_h:
            result["reason"] = f"too_small({w}x{h})"
            return result

        # 模糊检测
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        laplacian_var = cv2.Laplacian(gray, cv2.CV_64F).var()
        if laplacian_var < blur_thresh:
            result["reason"] = f"blurry(laplacian={laplacian_var:.1f})"
            return result

        # 人脸检测
        faces = face_app.get(img)
        if len(faces) == 0:
            result["reason"] = "no_face"
            return result

        # 只要有人脸（置信度>=阈值）就算合格
        valid_faces = [f for f in faces if f.det_score >= FACE_CONFIDENCE]
        if len(valid_faces) == 0:
            result["reason"] = "low_confidence_faces"
            return result

        result["ok"] = True
        result["faces"] = len(valid_faces)
        result["laplacian"] = round(laplacian_var, 1)
        return result

    except Exception as e:
        result["reason"] = str(e)
        return result


def collect_photos(root_dir: str) -> list[str]:
    paths = []
    for dirpath, _, filenames in os.walk(root_dir):
        for f in filenames:
            if Path(f).suffix.lower() in IMAGE_EXTS:
                paths.append(os.path.join(dirpath, f))
    return paths


def copy_photo(src: str, dst_dir: str, dry_run: bool = False) -> bool:
    dst = os.path.join(dst_dir, os.path.basename(src))
    if os.path.exists(dst):
        base, ext = os.path.splitext(os.path.basename(src))
        i = 1
        while os.path.exists(dst):
            dst = os.path.join(dst_dir, f"{base}_{i}{ext}")
            i += 1
    if dry_run:
        return True
    os.makedirs(dst_dir, exist_ok=True)
    shutil.copy2(src, dst)
    return True


def main():
    parser = argparse.ArgumentParser(description="筛选质量好且有人物的照片")
    parser.add_argument("--input", "-i", required=True, help="输入目录")
    parser.add_argument("--output", "-o", required=True, help="输出目录（合格照片）")
    parser.add_argument("--blur-threshold", type=int, default=LAPLACIAN_THRESHOLD,
                        help=f"模糊阈值（默认{LAPLACIAN_THRESHOLD}，越大越严格）")
    parser.add_argument("--min-width", type=int, default=MIN_WIDTH, help=f"最小宽度（默认{MIN_WIDTH}）")
    parser.add_argument("--min-height", type=int, default=MIN_HEIGHT, help=f"最小高度（默认{MIN_HEIGHT}）")
    parser.add_argument("--dry-run", action="store_true", help="只统计，不复制")
    parser.add_argument("--workers", type=int, default=MAX_WORKERS, help=f"并行数（默认{MAX_WORKERS}）")
    args = parser.parse_args()

    input_dir = os.path.abspath(args.input)
    output_dir = os.path.abspath(args.output)

    print(f"扫描目录: {input_dir}")
    photos = collect_photos(input_dir)
    print(f"找到 {len(photos)} 张图片\n")

    if not photos:
        return

    total = len(photos)
    passed = 0
    failed = 0

    # 预处理：排除明显不支持的格式
    from PIL import UnidentifiedImageError
    filtered = []
    for p in photos:
        try:
            with Image.open(p) as im:
                im.verify()
            filtered.append(p)
        except Exception:
            failed += 1

    if not filtered:
        print("没有可处理的图片")
        return

    print(f"开始检测（{args.workers} worker）...")
    with ProcessPoolExecutor(max_workers=args.workers, initializer=init_worker) as executor:
        futures = {executor.submit(check_photo, p, args.min_width, args.min_height, args.blur_threshold): p for p in filtered}
        for i, future in enumerate(as_completed(futures), 1):
            r = future.result()
            if r["ok"]:
                passed += 1
                copy_photo(r["path"], output_dir, dry_run=args.dry_run)
                print(f"  ✓ [{i}/{total}] {os.path.basename(r['path'])} ({r['faces']}人脸, laplacian={r['laplacian']})")
            else:
                failed += 1
                if r["reason"] != "no_face":
                    print(f"  ✗ [{i}/{total}] {os.path.basename(r['path'])} - {r['reason']}")

    print(f"\n完成! 合格: {passed}, 淘汰: {failed}")
    if not args.dry_run:
        print(f"输出目录: {output_dir}")


if __name__ == "__main__":
    main()