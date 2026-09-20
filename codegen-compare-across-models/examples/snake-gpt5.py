import pygame, sys, random

CELL = 20
GRID_W, GRID_H = 30, 24
WIDTH, HEIGHT = CELL * GRID_W, CELL * GRID_H
FPS = 12

pygame.init()
screen = pygame.display.set_mode((WIDTH, HEIGHT))
clock = pygame.time.Clock()
font = pygame.font.SysFont(None, 32)

def draw_cell(pos, color):
    pygame.draw.rect(screen, color, (*pos, CELL, CELL))

def random_food(snake):
    while True:
        f = (random.randrange(0, GRID_W) * CELL,
             random.randrange(0, GRID_H) * CELL)
        if f not in snake:
            return f

def main():
    direction = (CELL, 0)  # 初始向右
    snake = [(CELL*5, CELL*5), (CELL*4, CELL*5), (CELL*3, CELL*5)]
    food = random_food(snake)
    score = 0
    alive = True

    while True:
        for e in pygame.event.get():
            if e.type == pygame.QUIT:
                pygame.quit(); sys.exit()
            if e.type == pygame.KEYDOWN and alive:
                if e.key == pygame.K_UP and direction[1] == 0:
                    direction = (0, -CELL)
                elif e.key == pygame.K_DOWN and direction[1] == 0:
                    direction = (0, CELL)
                elif e.key == pygame.K_LEFT and direction[0] == 0:
                    direction = (-CELL, 0)
                elif e.key == pygame.K_RIGHT and direction[0] == 0:
                    direction = (CELL, 0)
            if e.type == pygame.KEYDOWN and not alive:
                if e.key == pygame.K_r:
                    return main()

        if alive:
            head_x, head_y = snake[0]
            new_head = (head_x + direction[0], head_y + direction[1])

            # 碰撞检测
            if (new_head[0] < 0 or new_head[0] >= WIDTH or
                new_head[1] < 0 or new_head[1] >= HEIGHT or
                new_head in snake):
                alive = False
            else:
                snake.insert(0, new_head)
                if new_head == food:
                    score += 1
                    food = random_food(snake)
                else:
                    snake.pop()

        screen.fill((18, 18, 18))
        # 画网格(可选)
        for x in range(0, WIDTH, CELL):
            pygame.draw.line(screen, (30,30,30), (x,0), (x,HEIGHT))
        for y in range(0, HEIGHT, CELL):
            pygame.draw.line(screen, (30,30,30), (0,y), (WIDTH,y))

        # 食物
        draw_cell(food, (220, 60, 60))
        # 蛇
        for i, seg in enumerate(snake):
            c = (80,200,120) if i else (50,170,95)
            draw_cell(seg, c)

        # 分数
        txt = font.render(f"Score: {score}", True, (240,240,240))
        screen.blit(txt, (10, 5))

        if not alive:
            over = font.render("Game Over - Press R to Restart", True, (250,180,60))
            screen.blit(over, (WIDTH//2 - over.get_width()//2, HEIGHT//2 - 20))

        pygame.display.flip()
        clock.tick(FPS)

if __name__ == "__main__":
    main()