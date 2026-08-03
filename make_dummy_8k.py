sentence = "The quick brown fox jumps over the lazy dog near the riverbank while the sun sets slowly behind the distant mountains. "
words_per_token = 0.75  # standard heuristic for English text (~1.33 tokens/word)
target_tokens = 8000
target_words = int(target_tokens * words_per_token)

words = (sentence * 1000).split()
words = words[:target_words]
while len(words) < target_words:
    words.extend(sentence.split())
    words = words[:target_words]

final_text = " ".join(words)

out_path = r"C:\Dev\DecoAI_Assistant\dummy_8k_tokens.txt"
with open(out_path, "w", encoding="utf-8") as f:
    f.write(final_text)

print(f"Word count: {len(words)}")
print(f"Estimated token count (~{words_per_token} words/token): {int(len(words) / words_per_token)}")
print(f"Char count: {len(final_text)}")
print(f"Written to: {out_path}")
