import logging
import os
import tempfile
import uuid
from urllib.parse import unquote_plus

import boto3
from PIL import Image, ImageOps

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

THUMB_PREFIX = os.environ.get("THUMB_PREFIX", "thumbnails/")
DEST_BUCKET = os.environ.get("DEST_BUCKET")  # optional: separate bucket avoids recursion entirely
THUMB_SIZE = (
    int(os.environ.get("THUMB_WIDTH", "128")),
    int(os.environ.get("THUMB_HEIGHT", "128")),
)

FORMAT_MAP = {
    ".jpg": ("JPEG", "image/jpeg"),
    ".jpeg": ("JPEG", "image/jpeg"),
    ".png": ("PNG", "image/png"),
    ".gif": ("GIF", "image/gif"),
    ".webp": ("WEBP", "image/webp"),
    ".bmp": ("BMP", "image/bmp"),
    ".tif": ("TIFF", "image/tiff"),
    ".tiff": ("TIFF", "image/tiff"),
}


def process_record(record):
    bucket = record["s3"]["bucket"]["name"]
    key = unquote_plus(record["s3"]["object"]["key"])  # S3 event keys are URL-encoded

    # Guard against recursive invocation when writing back to the source bucket
    if key.startswith(THUMB_PREFIX):
        logger.info("Skipping thumbnail object: %s", key)
        return None

    ext = os.path.splitext(key)[1].lower()
    if ext not in FORMAT_MAP:
        logger.warning("Unsupported file type, skipping: %s", key)
        return None
    fmt, content_type = FORMAT_MAP[ext]

    tmp_dir = tempfile.gettempdir()
    uid = uuid.uuid4().hex
    download_path = os.path.join(tmp_dir, f"{uid}{ext}")   # flat, collision-free paths
    thumbnail_path = os.path.join(tmp_dir, f"{uid}-thumb{ext}")

    try:
        s3.download_file(bucket, key, download_path)

        with Image.open(download_path) as img:
            img = ImageOps.exif_transpose(img)  # respect camera orientation
            if fmt == "JPEG" and img.mode not in ("RGB", "L"):
                img = img.convert("RGB")         # JPEG can't store alpha/palette
            img.thumbnail(THUMB_SIZE)
            img.save(thumbnail_path, format=fmt)

        dir_name, file_name = os.path.split(key)
        thumbnail_key = f"{THUMB_PREFIX}{dir_name + '/' if dir_name else ''}thumb-{file_name}"
        dest_bucket = DEST_BUCKET or bucket

        s3.upload_file(
            thumbnail_path,
            dest_bucket,
            thumbnail_key,
            ExtraArgs={"ContentType": content_type},
        )
        logger.info("Created s3://%s/%s", dest_bucket, thumbnail_key)
        return {"source": key, "thumbnail": thumbnail_key, "bucket": dest_bucket}

    finally:
        # /tmp persists across warm invocations; clean up
        for path in (download_path, thumbnail_path):
            try:
                os.remove(path)
            except FileNotFoundError:
                pass


def lambda_handler(event, context):
    results, errors = [], []

    for record in event.get("Records", []):
        try:
            result = process_record(record)
            if result:
                results.append(result)
        except Exception as e:
            logger.exception("Failed to process record")
            errors.append(str(e))

    if errors:
        # Fail the invocation so S3 async retries / DLQ / on-failure destination kick in
        raise RuntimeError(f"{len(errors)} record(s) failed: {errors}")

    return {"status": "Thumbnail(s) created", "thumbnails": results}
