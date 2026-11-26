import { test, expect } from '@playwright/test';

test.describe('Web Elements', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/webelements');
  });

  test('simple input form accepts input', async ({ page }) => {
    const form = page.getByTestId('simple-form');
    const values = {
      'input-fullname': 'Test Automation',
      'input-email': 'test@example.com',
      'textarea-current-address': 'Teststraat 1, Amsterdam',
      'textarea-permanent-address': 'Proefweg 2, Utrecht',
    };
    for (const [testId, value] of Object.entries(values)) {
      await form.getByTestId(testId).fill(value);
    }
    await form.getByTestId('btn-submit').click();

    for (const [testId, value] of Object.entries(values)) {
      await expect(form.getByTestId(testId)).toHaveValue(value);
    }
  });

  test('checkboxes can be toggled', async ({ page }) => {
    await page.getByTestId('link-checkbox').click();
    await expect(page.getByRole('heading', { level: 2, name: 'Checkboxes' })).toBeVisible();

    const checkbox = page.getByRole('checkbox', { name: 'Checkbox 2' });
    await checkbox.check();
    await expect(checkbox).toBeChecked();
    await checkbox.uncheck();
    await expect(checkbox).not.toBeChecked();
  });
});
