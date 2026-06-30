import os
from PIL import Image
import pillow_avif

def create_thumbnails(input_dir, output_dir, size=(200, 200), format='WEBP'):
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)

    for filename in os.listdir(input_dir):
        if filename.lower().endswith(('.png', '.jpg', '.jpeg')):
            try:
                img_path = os.path.join(input_dir, filename)
                with Image.open(img_path) as img:
                    img.thumbnail(size)

                    base_name = os.path.splitext(filename)[0]
                    save_path = os.path.join(output_dir, f"{base_name}.{format.lower()}")

                    img.save(save_path, format=format, quality=80)
                    print(f"Processado: {filename} -> {save_path}")
            except Exception as e:
                print(f"Erro ao processar {filename}: {e}")

if __name__ == '__main__':
    create_thumbnails('originals', 'thumbnails', format='WEBP')
