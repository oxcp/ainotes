import tkinter as tk
from tkinter import messagebox
import ast
import operator as op

# 安全表达式求值（仅支持 + - * / 括号 小数，禁止任意代码执行）
_ALLOWED_BINOPS = {
    ast.Add: op.add,
    ast.Sub: op.sub,
    ast.Mult: op.mul,
    ast.Div: op.truediv,
}
_ALLOWED_UNARYOPS = {
    ast.UAdd: op.pos,
    ast.USub: op.neg,
}

def safe_eval(expr: str) -> float:
    expr = expr.strip()
    if not expr:
        return 0.0
    # 将常见符号转为 Python 运算符
    expr = expr.replace('×', '*').replace('÷', '/').replace('−', '-')
    tree = ast.parse(expr, mode='eval')

    def _eval(node):
        if isinstance(node, ast.Expression):
            return _eval(node.body)
        if isinstance(node, ast.Constant):  # Python 3.8+
            if isinstance(node.value, (int, float)):
                return node.value
            raise ValueError("仅允许数字")
        if isinstance(node, ast.Num):  # 兼容旧版本
            return node.n
        if isinstance(node, ast.BinOp) and type(node.op) in _ALLOWED_BINOPS:
            left = _eval(node.left)
            right = _eval(node.right)
            return _ALLOWED_BINOPS[type(node.op)](left, right)
        if isinstance(node, ast.UnaryOp) and type(node.op) in _ALLOWED_UNARYOPS:
            operand = _eval(node.operand)
            return _ALLOWED_UNARYOPS[type(node.op)](operand)
        if isinstance(node, ast.Expr):
            return _eval(node.value)
        if isinstance(node, ast.Tuple):  # 防止逗号表达式
            raise ValueError("不支持的表达式")
        # 其他一律不允许（如函数调用、变量、幂运算等）
        raise ValueError("不支持的运算或字符")

    result = _eval(tree)
    return float(result)

class Calculator(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("计算器")
        self.geometry("320x420")
        self.resizable(False, False)

        self.expr_var = tk.StringVar()

        self._build_ui()
        self._bind_keys()

    def _build_ui(self):
        entry = tk.Entry(self, textvariable=self.expr_var, font=("Segoe UI", 18), bd=4, relief="groove", justify="right")
        entry.grid(row=0, column=0, columnspan=4, sticky="nsew", padx=10, pady=12, ipady=10)

        btns = [
            ["C", "⌫", "(", ")"],
            ["7", "8", "9", "/"],
            ["4", "5", "6", "*"],
            ["1", "2", "3", "-"],
            ["0", ".", "=", "+"],
        ]

        for r in range(1, 6):
            self.grid_rowconfigure(r, weight=1)
        for c in range(4):
            self.grid_columnconfigure(c, weight=1)

        for r, row in enumerate(btns, start=1):
            for c, text in enumerate(row):
                btn = tk.Button(
                    self,
                    text=text,
                    font=("Segoe UI", 16),
                    command=lambda t=text: self.on_button(t),
                    bd=1
                )
                btn.grid(row=r, column=c, sticky="nsew", padx=6, pady=6, ipady=8)

    def _bind_keys(self):
        self.bind("<Return>", lambda e: self.on_button("="))
        self.bind("<KP_Enter>", lambda e: self.on_button("="))
        self.bind("<Escape>", lambda e: self.on_button("C"))
        self.bind("<BackSpace>", lambda e: self.on_button("⌫"))
        self.bind("<Key>", self.on_key)

    def on_key(self, event: tk.Event):
        ch = event.char
        # 允许输入的字符
        allowed = "0123456789+-*/()."
        mapping = {"×": "*", "÷": "/", "−": "-"}
        if ch in mapping:
            self._append(mapping[ch])
        elif ch in allowed:
            self._append(ch)
        # 阻止蜂鸣
        return "break"

    def on_button(self, text: str):
        if text == "C":
            self.expr_var.set("")
            return
        if text == "⌫":
            cur = self.expr_var.get()
            self.expr_var.set(cur[:-1])
            return
        if text == "=":
            expr = self.expr_var.get()
            try:
                val = safe_eval(expr)
                # 格式化输出：整数显示为不带小数
                if abs(val - int(val)) < 1e-12:
                    self.expr_var.set(str(int(val)))
                else:
                    # 限制小数位
                    self.expr_var.set(str(round(val, 12)).rstrip("0").rstrip("."))
            except ZeroDivisionError:
                messagebox.showerror("错误", "除数不能为0")
            except Exception:
                messagebox.showerror("错误", "表达式无效")
            return
        # 其他按钮：追加字符
        self._append(text)

    def _append(self, s: str):
        self.expr_var.set(self.expr_var.get() + s)

if __name__ == "__main__":
    Calculator().mainloop()