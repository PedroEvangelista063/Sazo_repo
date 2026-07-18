#!/usr/bin/env python3
"""
Split backup_data_only.sql into chunks and restore via supabase db query
"""
import subprocess
import os
import sys

BACKUP_FILE = r"D:\D\PROJETOS EM ANDAMENTO\quero_comprar_vg\backup_data_only.sql"
CHUNK_DIR = r"D:\D\PROJETOS EM ANDAMENTO\quero_comprar_vg\restore_chunks"
CHUNK_SIZE = 3000  # lines per chunk

def split_file():
    """Split the backup SQL into smaller chunks"""
    os.makedirs(CHUNK_DIR, exist_ok=True)
    
    with open(BACKUP_FILE, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    total_lines = len(lines)
    chunks = []
    
    # Find COPY statement boundaries
    i = 0
    chunk_num = 0
    current_chunk = []
    
    while i < total_lines:
        line = lines[i]
        current_chunk.append(line)
        
        # If we hit a COPY statement or reached chunk size, save the chunk
        if line.startswith('COPY ') and len(current_chunk) > 100:
            chunk_file = os.path.join(CHUNK_DIR, f"chunk_{chunk_num:04d}.sql")
            with open(chunk_file, 'w', encoding='utf-8') as f:
                f.writelines(current_chunk)
            chunks.append(chunk_file)
            current_chunk = []
            chunk_num += 1
        elif len(current_chunk) >= CHUNK_SIZE:
            chunk_file = os.path.join(CHUNK_DIR, f"chunk_{chunk_num:04d}.sql")
            with open(chunk_file, 'w', encoding='utf-8') as f:
                f.writelines(current_chunk)
            chunks.append(chunk_file)
            current_chunk = []
            chunk_num += 1
        
        i += 1
    
    # Save remaining lines
    if current_chunk:
        chunk_file = os.path.join(CHUNK_DIR, f"chunk_{chunk_num:04d}.sql")
        with open(chunk_file, 'w', encoding='utf-8') as f:
            f.writelines(current_chunk)
        chunks.append(chunk_file)
    
    return chunks

def restore_chunk(chunk_file):
    """Restore a single chunk via supabase db query"""
    cmd = ['npx', 'supabase', 'db', 'query', '--linked', '--file', chunk_file]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    return result.returncode, result.stdout, result.stderr

def main():
    print("Splitting backup file into chunks...")
    chunks = split_file()
    print(f"Created {len(chunks)} chunks")
    
    success = 0
    failed = 0
    
    for i, chunk in enumerate(chunks):
        print(f"\n[{i+1}/{len(chunks)}] Restoring {os.path.basename(chunk)}...")
        try:
            rc, stdout, stderr = restore_chunk(chunk)
            if rc == 0:
                print(f"  ✓ OK")
                success += 1
            else:
                print(f"  ✗ FAILED (rc={rc})")
                if stderr:
                    print(f"    Error: {stderr[:200]}")
                failed += 1
        except subprocess.TimeoutExpired:
            print(f"  ✗ TIMEOUT")
            failed += 1
        except Exception as e:
            print(f"  ✗ ERROR: {e}")
            failed += 1
    
    print(f"\n{'='*50}")
    print(f"Results: {success} success, {failed} failed out of {len(chunks)} chunks")
    
    return 0 if failed == 0 else 1

if __name__ == '__main__':
    sys.exit(main())
