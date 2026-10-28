"""软帮手智能体：AgentLens 的被测对象。

agent core 是纯 Python：不 import fastapi、不读 AppSession，只吃
(text, history, data_source, llm, policy)。HTTP 入口与 CLI 都只是它的薄封装，
这样 AgentLens 可以在进程外通过 CLI 复现任意一次执行。
"""
