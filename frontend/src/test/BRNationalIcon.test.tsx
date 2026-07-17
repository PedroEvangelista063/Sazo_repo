import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { BRNationalIcon } from '../components/BRNationalIcon'

describe('BRNationalIcon', () => {
  it('renderiza o ícone com bandeira BR e aria-label', () => {
    render(<BRNationalIcon onClick={() => {}} isActive={false} />)
    const btn = screen.getByRole('button', { name: /BR Nacional/i })
    expect(btn).toBeInTheDocument()
    expect(btn).toHaveTextContent('🇧🇷')
  })

  it('chama onClick ao clicar', async () => {
    const onClick = vi.fn()
    render(<BRNationalIcon onClick={onClick} isActive={false} />)
    const btn = screen.getByRole('button', { name: /BR Nacional/i })
    await userEvent.click(btn)
    expect(onClick).toHaveBeenCalledTimes(1)
  })

  it('aplica estilo ativo quando isActive é true', () => {
    const { container } = render(<BRNationalIcon onClick={() => {}} isActive={true} />)
    const btn = container.firstChild as HTMLElement
    // Verifica que o gradiente green-yellow está presente via style
    expect(btn.style.background).toContain('gradient')
  })

  it('mantém tamanho mínimo de toque (44px)', () => {
    render(<BRNationalIcon onClick={() => {}} isActive={false} />)
    const btn = screen.getByRole('button', { name: /BR Nacional/i })
    expect(btn.className).toMatch(/min-h-\[44px\]/)
    expect(btn.className).toMatch(/min-w-\[44px\]/)
  })

  it('partículas de fruta estão presentes no DOM', () => {
    const { container } = render(<BRNationalIcon onClick={() => {}} isActive={false} />)
    // Procura pelos emojis de fruta — devem existir 5 partículas
    const fruitEmojis = ['🍎', '🍌', '🍅', '🍊', '🍇']
    for (const emoji of fruitEmojis) {
      expect(container.textContent).toContain(emoji)
    }
  })
})
