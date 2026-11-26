import { test, expect } from '@playwright/test';

test.describe('Shopping app', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/shopping');
    await expect(page.getByRole('heading', { level: 1, name: 'E-commerce Testing Practice' })).toBeVisible();
  });

  test('search filters the product list', async ({ page }) => {
    await page.getByTestId('search-input').fill('Keyboard');
    await expect(page.getByRole('heading', { level: 2, name: /Search Results \(1 products?\)/ })).toBeVisible();
    await expect(page.getByRole('heading', { level: 3, name: 'Mechanical Keyboard' })).toBeVisible();
  });

  test('category filter only shows that category', async ({ page }) => {
    await page.getByTestId('category-filter').selectOption('Furniture');
    const cards = page.locator('[data-testid^="product-"]');
    await expect(cards.first()).toBeVisible();
    for (const card of await cards.all()) {
      await expect(card).toContainText('Furniture');
    }
  });

  test('out-of-stock product cannot be added', async ({ page }) => {
    await expect(page.getByRole('button', { name: 'Out of Stock' })).toBeDisabled();
  });

  test('adding a product updates the cart', async ({ page }) => {
    const cart = page.getByTestId('cart-button');
    await expect(cart).toContainText('0 items');

    await page.getByRole('heading', { level: 3, name: 'Desk Lamp' })
      .locator('xpath=ancestor::*[starts-with(@data-testid,"product-")][1]')
      .getByRole('button', { name: 'Add to Cart' })
      .click();

    await expect(cart).toContainText('1 item');
    await expect(cart).toContainText('$24.99');
  });
});
