#!/usr/bin/env python3
import requests
import sys
import os

def query_deepseek(prompt, model="deepseek-coder:1.3b"):
    """Query deepseek-coder via Ollama"""
    try:
        response = requests.post('http://localhost:11434/api/generate', json={
            'model': model,
            'prompt': prompt,
            'stream': False,
            'temperature': 0.7
        }, timeout=120)
        
        if response.status_code == 200:
            return response.json()['response']
        else:
            return f"Error: {response.status_code}"
    except requests.exceptions.ConnectionError:
        return "Error: Ollama not running. Start it with: ollama serve"

def read_file(filepath):
    """Read a file and return its content"""
    try:
        if not os.path.exists(filepath):
            return None
        with open(filepath, 'r') as f:
            return f.read()
    except Exception as e:
        return f"Error reading file: {e}"

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: codex 'your prompt here'")
        print("       codex 'Read myfile.py and explain it'")
        print("       codex 'Fix bugs in app.py'")
        sys.exit(1)
    
    prompt = ' '.join(sys.argv[1:])
    
    # Check if prompt asks to read a file
    words = prompt.lower().split()
    if 'read' in words or 'file' in words:
        # Try to extract filename
        for i, word in enumerate(words):
            if word in ['read', 'open']:
                if i + 1 < len(words):
                    filename = words[i + 1]
                    # Try common paths
                    for path in [filename, f"./{filename}", f"~/{filename}".replace("~", os.path.expanduser("~"))]:
                        content = read_file(path)
                        if content and not content.startswith("Error"):
                            prompt = f"Here is the content of {filename}:\n\n{content}\n\nNow: {prompt}"
                            break
    
    print("\n🤖 Generating code...\n")
    result = query_deepseek(prompt)
    print(result)