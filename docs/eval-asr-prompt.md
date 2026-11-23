# ASR prompt 该放什么词（2026-11-23 实测）

`ASRPrompt.build()` 把 `baseTerms` 加上用户词典里能塞进 300 字符的词，拼成 Whisper 的初始
prompt。这份文档记录一次改动前后的对照，因为改这里的成本只能靠录音复现，靠推理猜不出来。

## 方法

13 条归档录音（`~/.voicepad/audio`，取自 `docs/eval-script.md` 的段 1/2/3/4），用
`VoicePad --transcribe <wav>` 逐条重放，`scripts/eval_report.py --hyp` 打分。
`--transcribe` 走的是和线上同一份 `ASRPrompt.build(vocabulary:)`，所以测的是线上 prompt。

## 结果（13 条，单次采样）

| 版本 | prompt 内容 | CER | CER（忽略数字） | 英文术语保留 | 段 3 专名 |
|---|---|---:|---:|---:|---|
| before | 原 baseTerms（17 个）+ 无词典 | 10.7% | 8.8% | 16/21 = 76% | 东方**军**信 / 火**腹**牛 / **军**性 |
| v1 | 只留产品名，砍掉 ML 黑话 | 12.2% | 10.4% | 15/21 = 71% | 同上，未修 |
| v3 | 产品名 + 中文名（词典前 48 词） | 8.5% | 8.8% | 13/21 = 62% | 东方**君**信 / 火**富**牛 / **君**信 ✓ |
| v4 | v3 的最终形态（= 现在线上的配置） | 8.5% | 8.8% | 13/21 = 62% | 同上 ✓ |
| v5 | 原 baseTerms 不动 + 中文名 | 9.4% | 9.8% | 13/21 = 62% | 只修好火**富**牛 |

## 结论

1. **中文名进 prompt 有用，而且是唯一有用的通道。** 原设计用 `containsLatinLetter` 把中文名
   过滤掉了，理由是"中文由声学模型处理"——实测不成立：`东方君信`/`火富牛` 这类私有名字
   声学模型必错，而错法（军信/腹牛）下游的改写层和 alias 都救不回来。拉丁字母的拼写错
   （`MagPy`、`Sherpa Onyx`）改写层认得出来，所以值得把 prompt 预算让给中文名。
2. **代价是英文术语保留从 76% 掉到 62%**，且 prompt 里中英混排会让 Whisper 在拉丁词前后
   插入空格（`把 VoicePad的`）。这部分交给别名（`voice pad → VoicePad`）和改写层兜底。
3. **砍掉从不口述的 ML 黑话是错的**（v1，CER 反升 1.5pp）。这份评测集本身来自那 17 个词
   的选词实验，删词只能在它上面表现为退步；保留 `CER`/`benchmark`/`config schema` 这些，
   腾出的预算给中文名。
4. **单次采样，方差没测**。13 条里 3 条专名，结论方向可信，具体百分点不可信。要动这里，
   先加录音（`docs/eval-script.md`），再跑同样的 `--hyp` 对照。

## 复现

```bash
swift build
DYLD_LIBRARY_PATH=$PWD/Frameworks/sherpa-onnx/lib \
  .build/arm64-apple-macosx/debug/VoicePad --transcribe ~/.voicepad/audio/<x>.wav
python3 scripts/eval_report.py --hyp <hyp.jsonl> --label <版本>
```
