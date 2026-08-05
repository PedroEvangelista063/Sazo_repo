import { describe, it, expect } from 'vitest'
import { fireEvent, render } from '@testing-library/react'
import { DynamicBackground } from '../components/DynamicBackground'
import { BANDEIRAS_UF } from '../utils/bandeirasUf'

const TOTAL_UFS = Object.keys(BANDEIRAS_UF).length // 27

describe('DynamicBackground', () => {
  it('renderiza a camada do mapa (slide) sempre', () => {
    const { container } = render(<DynamicBackground />)
    const mapa = container.querySelector('[data-testid="bg-mapa"]')
    expect(mapa).toBeInTheDocument()
    expect(mapa?.className).toContain('animate-slide-horizontal')
    expect(mapa?.getAttribute('style')).toContain('background-image')
  })

  describe('viewType cards', () => {
    it('não renderiza bandeira sem UF ou com BR', () => {
      const { container, rerender } = render(<DynamicBackground viewType="cards" />)
      expect(container.querySelector('[data-testid="bg-bandeira"]')).not.toBeInTheDocument()

      rerender(<DynamicBackground uf="BR" viewType="cards" />)
      expect(container.querySelector('[data-testid="bg-bandeira"]')).not.toBeInTheDocument()
    })

    it('centraliza a bandeira de SP com a URL correta e animação combinada', () => {
      const { container } = render(<DynamicBackground uf="SP" viewType="cards" />)
      const img = container.querySelector('[data-testid="bg-bandeira"]')
      expect(img).toBeInTheDocument()
      expect(img?.getAttribute('src')).toContain('Bandeira_do_estado_de_S%C3%A3o_Paulo.svg')
      // Animação combinada única (blink + pulse num keyframe — evita conflito de cascade)
      expect(img?.className).toContain('animate-flag-breathe')
      expect(img?.parentElement?.className).toContain('top-1/2')
      expect(img?.parentElement?.className).toContain('-translate-y-1/2')
    })

    it('oculta a bandeira quando a imagem falha ao carregar (onError)', () => {
      const { container } = render(<DynamicBackground uf="RS" viewType="cards" />)
      const img = container.querySelector('[data-testid="bg-bandeira"]')
      expect(img).toBeInTheDocument()

      fireEvent.error(img as Element)
      expect(container.querySelector('[data-testid="bg-bandeira"]')).not.toBeInTheDocument()
    })
  })

  describe('viewType grade (carrossel monocromático)', () => {
    it('renderiza todas as 27 bandeiras no rodapé, monocromáticas e escalonadas', () => {
      const { container } = render(<DynamicBackground viewType="grade" />)

      const carrossel = container.querySelector('[data-testid="bg-carrossel"]')
      expect(carrossel).toBeInTheDocument()
      expect(carrossel?.className).toContain('bottom-0')

      const imgs = container.querySelectorAll('[data-testid="bg-bandeira-carrossel"]')
      expect(imgs.length).toBe(TOTAL_UFS)

      imgs.forEach((img) => {
        expect(img?.className).toContain('animate-flag-cycle')
        expect(img?.className).toContain('grayscale') // padrão monocromático
        expect(img?.getAttribute('style')).toContain('animation-delay')
      })

      // Stagger negativo e progressivo: cada bandeira atrasada 6s em relação à anterior
      const delays = Array.from(imgs).map((img) => img?.getAttribute('style'))
      expect(delays[0]).toContain('0s')
      expect(delays[1]).toContain('-6s')
      expect(delays[TOTAL_UFS - 1]).toContain(`-${(TOTAL_UFS - 1) * 6}s`)
    })

    it('oculta apenas a bandeira que falhou ao carregar (mantém as demais)', () => {
      const { container } = render(<DynamicBackground viewType="grade" />)
      const imgs = container.querySelectorAll('[data-testid="bg-bandeira-carrossel"]')
      expect(imgs.length).toBe(TOTAL_UFS)

      fireEvent.error(imgs[0] as Element)
      const restantes = container.querySelectorAll('[data-testid="bg-bandeira-carrossel"]')
      expect(restantes.length).toBe(TOTAL_UFS - 1)
    })
  })
})
