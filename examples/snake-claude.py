import pygame
import random
import sys

# Initialize Pygame
pygame.init()

# Game settings
WINDOW_WIDTH = 800
WINDOW_HEIGHT = 600
GRID_SIZE = 20
GRID_WIDTH = WINDOW_WIDTH // GRID_SIZE
GRID_HEIGHT = WINDOW_HEIGHT // GRID_SIZE
FPS = 10

# Colors
BLACK = (0, 0, 0)
WHITE = (255, 255, 255)
GREEN = (0, 255, 0)
RED = (255, 0, 0)
DARK_GREEN = (0, 200, 0)

class Snake:
    def __init__(self):
        self.length = 1
        self.positions = [((GRID_WIDTH // 2), (GRID_HEIGHT // 2))]
        self.direction = random.choice([0, 1, 2, 3])
        self.color = GREEN
        self.score = 0

    def get_head_position(self):
        return self.positions[0]

    def update(self):
        cur = self.get_head_position()
        x, y = self.direction_to_movement(self.direction)
        new = (((cur[0] + x) % GRID_WIDTH), ((cur[1] + y) % GRID_HEIGHT))
        
        if len(self.positions) > 2 and new in self.positions[2:]:
            return False  # Game over
        else:
            self.positions.insert(0, new)
            if len(self.positions) > self.length:
                self.positions.pop()
        return True

    def direction_to_movement(self, direction):
        if direction == 0:  # UP
            return (0, -1)
        elif direction == 1:  # DOWN
            return (0, 1)
        elif direction == 2:  # LEFT
            return (-1, 0)
        else:  # RIGHT
            return (1, 0)

    def reset(self):
        self.length = 1
        self.positions = [((GRID_WIDTH // 2), (GRID_HEIGHT // 2))]
        self.direction = random.choice([0, 1, 2, 3])
        self.score = 0

    def render(self, surface):
        for i, p in enumerate(self.positions):
            color = DARK_GREEN if i == 0 else self.color
            rect = pygame.Rect((p[0] * GRID_SIZE, p[1] * GRID_SIZE), 
                              (GRID_SIZE, GRID_SIZE))
            pygame.draw.rect(surface, color, rect)
            pygame.draw.rect(surface, BLACK, rect, 1)

class Food:
    def __init__(self):
        self.position = (0, 0)
        self.color = RED
        self.randomize_position()

    def randomize_position(self):
        self.position = (random.randint(0, GRID_WIDTH - 1), 
                        random.randint(0, GRID_HEIGHT - 1))

    def render(self, surface):
        rect = pygame.Rect((self.position[0] * GRID_SIZE, 
                           self.position[1] * GRID_SIZE), 
                          (GRID_SIZE, GRID_SIZE))
        pygame.draw.rect(surface, self.color, rect)
        pygame.draw.rect(surface, BLACK, rect, 1)

class Game:
    def __init__(self):
        self.screen = pygame.display.set_mode((WINDOW_WIDTH, WINDOW_HEIGHT))
        pygame.display.set_caption("贪吃蛇游戏")
        self.clock = pygame.time.Clock()
        self.font = pygame.font.Font(None, 36)
        self.snake = Snake()
        self.food = Food()
        self.running = True
        self.game_over = False

    def handle_events(self):
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                self.running = False
            elif event.type == pygame.KEYDOWN:
                if self.game_over:
                    if event.key == pygame.K_SPACE:
                        self.reset_game()
                else:
                    if event.key == pygame.K_UP and self.snake.direction != 1:
                        self.snake.direction = 0
                    elif event.key == pygame.K_DOWN and self.snake.direction != 0:
                        self.snake.direction = 1
                    elif event.key == pygame.K_LEFT and self.snake.direction != 3:
                        self.snake.direction = 2
                    elif event.key == pygame.K_RIGHT and self.snake.direction != 2:
                        self.snake.direction = 3

    def update(self):
        if not self.game_over:
            if not self.snake.update():
                self.game_over = True
                return

            # Check if snake ate food
            if self.snake.get_head_position() == self.food.position:
                self.snake.length += 1
                self.snake.score += 10
                self.food.randomize_position()
                
                # Make sure food doesn't spawn on snake
                while self.food.position in self.snake.positions:
                    self.food.randomize_position()

    def render(self):
        self.screen.fill(BLACK)
        
        if not self.game_over:
            self.snake.render(self.screen)
            self.food.render(self.screen)
            
            # Display score
            score_text = self.font.render(f"Score: {self.snake.score}", 
                                         True, WHITE)
            self.screen.blit(score_text, (10, 10))
        else:
            # Game over screen
            game_over_text = self.font.render("GAME OVER", True, RED)
            score_text = self.font.render(f"Final Score: {self.snake.score}", 
                                         True, WHITE)
            restart_text = self.font.render("Press SPACE to restart", 
                                           True, WHITE)
            
            text_rect = game_over_text.get_rect(center=(WINDOW_WIDTH // 2, 
                                                        WINDOW_HEIGHT // 2 - 50))
            score_rect = score_text.get_rect(center=(WINDOW_WIDTH // 2, 
                                                     WINDOW_HEIGHT // 2))
            restart_rect = restart_text.get_rect(center=(WINDOW_WIDTH // 2, 
                                                         WINDOW_HEIGHT // 2 + 50))
            
            self.screen.blit(game_over_text, text_rect)
            self.screen.blit(score_text, score_rect)
            self.screen.blit(restart_text, restart_rect)
        
        pygame.display.flip()

    def reset_game(self):
        self.snake.reset()
        self.food.randomize_position()
        self.game_over = False

    def run(self):
        while self.running:
            self.handle_events()
            self.update()
            self.render()
            self.clock.tick(FPS)
        
        pygame.quit()
        sys.exit()

if __name__ == "__main__":
    game = Game()
    game.run()