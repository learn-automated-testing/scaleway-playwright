import { test, expect } from '@playwright/test';

test.describe('Home page', () => {
  test('shows hero and main navigation', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveTitle('Home');
    await expect(page.getByRole('heading', { level: 1, name: 'Master Automated Testing' })).toBeVisible();

    const nav = page.getByRole('navigation', { name: 'Main navigation' });
    for (const item of ['Home', 'Web Elements', 'API', 'Shopping', 'AI Tools']) {
      await expect(nav.getByRole('link', { name: item })).toBeVisible();
    }
  });

  test('"Get Started" leads to Web Elements', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('link', { name: 'Get Started' }).click();
    await expect(page).toHaveURL(/\/webelements$/);
    await expect(page.getByRole('heading', { level: 1, name: 'Web Elements Testing' })).toBeVisible();
  });
});
