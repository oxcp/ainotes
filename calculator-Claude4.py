import tkinter as tk
from tkinter import ttk
import math

class Calculator:
    def __init__(self, root):
        self.root = root
        self.root.title("计算器")
        self.root.geometry("400x600")
        self.root.resizable(False, False)
        
        # 设置样式
        self.root.configure(bg='#1e1e1e')
        
        # 当前输入和结果
        self.current_input = ""
        self.result = 0
        self.operation_pending = False
        
        # 创建界面
        self.create_widgets()
        
    def create_widgets(self):
        # 显示屏
        self.display_frame = tk.Frame(self.root, bg='#1e1e1e')
        self.display_frame.pack(fill='both', expand=True, padx=10, pady=10)
        
        # 输入显示
        self.input_label = tk.Label(
            self.display_frame,
            text="0",
            font=('Arial', 24),
            bg='#2d2d30',
            fg='white',
            anchor='e',
            padx=10,
            pady=10
        )
        self.input_label.pack(fill='both', expand=True)
        
        # 结果显示
        self.result_label = tk.Label(
            self.display_frame,
            text="",
            font=('Arial', 18),
            bg='#2d2d30',
            fg='#888',
            anchor='e',
            padx=10,
            pady=5
        )
        self.result_label.pack(fill='both', expand=True)
        
        # 按钮框架
        self.buttons_frame = tk.Frame(self.root, bg='#1e1e1e')
        self.buttons_frame.pack(fill='both', expand=True, padx=5, pady=5)
        
        # 按钮布局
        buttons = [
            ['C', '⌫', '%', '÷'],
            ['7', '8', '9', '×'],
            ['4', '5', '6', '−'],
            ['1', '2', '3', '+'],
            ['±', '0', '.', '=']
        ]
        
        # 特殊按钮样式
        special_buttons = ['C', '⌫', '%', '÷', '×', '−', '+', '=']
        
        # 创建按钮
        for i, row in enumerate(buttons):
            row_frame = tk.Frame(self.buttons_frame, bg='#1e1e1e')
            row_frame.pack(fill='both', expand=True, pady=2)
            
            for j, btn_text in enumerate(row):
                # 设置按钮颜色
                if btn_text == '=':
                    bg_color = '#007acc'
                    hover_color = '#005a9e'
                elif btn_text in special_buttons:
                    bg_color = '#3c3c3c'
                    hover_color = '#4a4a4a'
                else:
                    bg_color = '#2d2d30'
                    hover_color = '#3a3a3a'
                
                btn = tk.Button(
                    row_frame,
                    text=btn_text,
                    font=('Arial', 18, 'bold'),
                    bg=bg_color,
                    fg='white',
                    borderwidth=0,
                    command=lambda x=btn_text: self.button_click(x),
                    activebackground=hover_color,
                    activeforeground='white',
                    width=5,
                    height=2
                )
                btn.pack(side='left', fill='both', expand=True, padx=2)
                
                # 鼠标悬停效果
                btn.bind("<Enter>", lambda e, b=btn, c=hover_color: b.config(bg=c))
                btn.bind("<Leave>", lambda e, b=btn, c=bg_color: b.config(bg=c))
        
        # 添加科学计算按钮
        self.add_scientific_buttons()
        
    def add_scientific_buttons(self):
        # 科学计算框架
        sci_frame = tk.Frame(self.root, bg='#1e1e1e')
        sci_frame.pack(fill='x', padx=5, pady=5)
        
        sci_buttons = ['sin', 'cos', 'tan', '√', 'x²', 'log', 'ln', 'π']
        
        for i, btn_text in enumerate(sci_buttons):
            btn = tk.Button(
                sci_frame,
                text=btn_text,
                font=('Arial', 12),
                bg='#3c3c3c',
                fg='white',
                borderwidth=0,
                command=lambda x=btn_text: self.scientific_operation(x),
                width=4,
                height=1
            )
            btn.grid(row=0, column=i, padx=2, pady=2)
            
            # 鼠标悬停效果
            btn.bind("<Enter>", lambda e, b=btn: b.config(bg='#4a4a4a'))
            btn.bind("<Leave>", lambda e, b=btn: b.config(bg='#3c3c3c'))
    
    def button_click(self, value):
        if value == 'C':
            self.clear()
        elif value == '⌫':
            self.backspace()
        elif value == '=':
            self.calculate()
        elif value == '±':
            self.toggle_sign()
        elif value in ['÷', '×', '−', '+', '%']:
            self.add_operator(value)
        elif value == '.':
            self.add_decimal()
        else:
            self.add_number(value)
    
    def clear(self):
        self.current_input = ""
        self.result = 0
        self.input_label.config(text="0")
        self.result_label.config(text="")
        self.operation_pending = False
    
    def backspace(self):
        if self.current_input:
            self.current_input = self.current_input[:-1]
            if not self.current_input:
                self.input_label.config(text="0")
            else:
                self.input_label.config(text=self.current_input)
    
    def add_number(self, num):
        if self.operation_pending:
            self.current_input = ""
            self.operation_pending = False
        
        if self.current_input == "0":
            self.current_input = num
        else:
            self.current_input += num
        
        self.input_label.config(text=self.current_input)
    
    def add_operator(self, op):
        if self.current_input and not self.current_input[-1] in ['÷', '×', '−', '+', '%']:
            # 转换操作符
            operator_map = {'÷': '/', '×': '*', '−': '-'}
            op_display = op
            op = operator_map.get(op, op)
            
            self.current_input += op_display
            self.input_label.config(text=self.current_input)
    
    def add_decimal(self):
        # 检查当前数字是否已有小数点
        parts = self.current_input.replace('+', ' ').replace('-', ' ').replace('*', ' ').replace('/', ' ').split()
        if parts and '.' not in parts[-1]:
            if not self.current_input or self.current_input[-1] in ['÷', '×', '−', '+']:
                self.current_input += '0.'
            else:
                self.current_input += '.'
            self.input_label.config(text=self.current_input)
    
    def toggle_sign(self):
        if self.current_input:
            try:
                # 简单实现：如果是单个数字，切换符号
                result = eval(self.current_input.replace('÷', '/').replace('×', '*').replace('−', '-'))
                self.current_input = str(-result)
                self.input_label.config(text=self.current_input)
            except:
                pass
    
    def calculate(self):
        if self.current_input:
            try:
                # 替换显示符号为实际运算符
                expression = self.current_input.replace('÷', '/').replace('×', '*').replace('−', '-')
                
                # 计算结果
                result = eval(expression)
                
                # 格式化结果
                if result == int(result):
                    result = int(result)
                
                self.result_label.config(text=f"= {result}")
                self.current_input = str(result)
                self.input_label.config(text=self.current_input)
                self.operation_pending = True
                
            except ZeroDivisionError:
                self.result_label.config(text="错误：除数不能为零")
            except:
                self.result_label.config(text="错误：无效表达式")
    
    def scientific_operation(self, op):
        try:
            if self.current_input:
                value = float(eval(self.current_input.replace('÷', '/').replace('×', '*').replace('−', '-')))
                
                if op == 'sin':
                    result = math.sin(math.radians(value))
                elif op == 'cos':
                    result = math.cos(math.radians(value))
                elif op == 'tan':
                    result = math.tan(math.radians(value))
                elif op == '√':
                    result = math.sqrt(value)
                elif op == 'x²':
                    result = value ** 2
                elif op == 'log':
                    result = math.log10(value)
                elif op == 'ln':
                    result = math.log(value)
                elif op == 'π':
                    self.current_input = str(math.pi)
                    self.input_label.config(text=self.current_input)
                    return
                
                # 格式化结果
                if result == int(result):
                    result = int(result)
                else:
                    result = round(result, 10)
                
                self.current_input = str(result)
                self.input_label.config(text=self.current_input)
                self.result_label.config(text=f"{op}({value}) = {result}")
                
        except ValueError as e:
            self.result_label.config(text="错误：数学域错误")
        except:
            self.result_label.config(text="错误：无效操作")

def main():
    root = tk.Tk()
    calculator = Calculator(root)
    
    # 绑定键盘事件
    def key_press(event):
        key = event.char
        if key.isdigit():
            calculator.add_number(key)
        elif key in ['+', '-', '*', '/']:
            operator_map = {'/': '÷', '*': '×', '-': '−'}
            calculator.add_operator(operator_map.get(key, key))
        elif key == '.':
            calculator.add_decimal()
        elif key == '\r':  # Enter键
            calculator.calculate()
        elif key == '\x08':  # Backspace键
            calculator.backspace()
        elif key.lower() == 'c':
            calculator.clear()
    
    root.bind('<Key>', key_press)
    root.mainloop()

if __name__ == "__main__":
    main()