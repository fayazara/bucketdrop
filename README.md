# BucketDrop

<img width="1280" height="800" alt="Preview 1" src="https://github.com/user-attachments/assets/a37fd19a-7711-49a6-b5f4-40d9024508b4" />

Bucketdrop is a simple macOS menubar app for uploading files to S3-compatible storage (Cloudflare R2, AWS S3, MinIO, etc.).


## Features

- Drag & drop files to upload instantly
- Click to select files from Finder
- Supports multiple file uploads
- URLs automatically copied to clipboard
- Quick Look preview for files
- Download files directly to your Mac
- Works with AWS S3, Cloudflare R2, MinIO, and other S3-compatible services

## Installation

1. Move `BucketDrop.app` to your Applications folder
2. Open the app - it will appear in your menubar

## Setup

1. Click the BucketDrop icon in the menubar
2. Click the gear icon to open Settings
3. Enter your S3 credentials:
   - **Access Key ID**
   - **Secret Access Key**
   - **Bucket Name**
   - **Region** (e.g., `us-east-1`, or `auto` for Cloudflare R2)
4. For S3-compatible services (R2, MinIO):
   - **S3 Endpoint** - Your service's S3 API endpoint
   - **Public URL Base** - Your custom domain for accessing files
5. Click "Test Connection" to verify, then "Save"

## Usage

- **Drag & drop** files onto the menubar popover to upload
- **Click** the drop zone to select files from Finder
- **Double-click** a file in the list to preview with Quick Look
- **Hover** over a file to see action buttons (copy URL, download, delete)

Uploaded file URLs are automatically copied to your clipboard.

## Requirements

- macOS 14.0 (Sonoma) or later

## License

MIT
