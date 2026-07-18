import type { BRStateData, BRStateUF, Locale } from './types';
import { getStateName, getRegionName } from './i18n';

export const statesData: Record<BRStateUF, BRStateData> = {
  AC: {
    uf: 'AC',
    name: 'Acre',
    capital: 'Rio Branco',
    region: 'North',
    coordinates: { latitude: -9.0238, longitude: -70.812 },
    population: 906876,
    area: 164123.04,
    timezone: 'America/Rio_Branco',
    utcOffset: -5,
    iso: 'BR-AC'
  },
  AL: {
    uf: 'AL',
    name: 'Alagoas',
    capital: 'Maceió',
    region: 'Northeast',
    coordinates: { latitude: -9.5713, longitude: -36.782 },
    population: 3365351,
    area: 27843.295,
    timezone: 'America/Maceio',
    utcOffset: -3,
    iso: 'BR-AL'
  },
  AP: {
    uf: 'AP',
    name: 'Amapá',
    capital: 'Macapá',
    region: 'North',
    coordinates: { latitude: 0.9019, longitude: -52.003 },
    population: 877613,
    area: 142470.762,
    timezone: 'America/Belem',
    utcOffset: -3,
    iso: 'BR-AP'
  },
  AM: {
    uf: 'AM',
    name: 'Amazonas',
    capital: 'Manaus',
    region: 'North',
    coordinates: { latitude: -3.4168, longitude: -65.8561 },
    population: 4269995,
    area: 1559159.148,
    timezone: 'America/Manaus',
    utcOffset: -4,
    iso: 'BR-AM'
  },
  BA: {
    uf: 'BA',
    name: 'Bahia',
    capital: 'Salvador',
    region: 'Northeast',
    coordinates: { latitude: -12.5797, longitude: -41.7007 },
    population: 14985284,
    area: 564732.45,
    timezone: 'America/Bahia',
    utcOffset: -3,
    iso: 'BR-BA'
  },
  CE: {
    uf: 'CE',
    name: 'Ceará',
    capital: 'Fortaleza',
    region: 'Northeast',
    coordinates: { latitude: -5.4984, longitude: -39.3206 },
    population: 9240580,
    area: 148894.442,
    timezone: 'America/Fortaleza',
    utcOffset: -3,
    iso: 'BR-CE'
  },
  DF: {
    uf: 'DF',
    name: 'Distrito Federal',
    capital: 'Brasília',
    region: 'Central-West',
    coordinates: { latitude: -15.7939, longitude: -47.8828 },
    population: 3094325,
    area: 5760.784,
    timezone: 'America/Sao_Paulo',
    utcOffset: -3,
    iso: 'BR-DF'
  },
  ES: {
    uf: 'ES',
    name: 'Espírito Santo',
    capital: 'Vitória',
    region: 'Southeast',
    coordinates: { latitude: -19.1834, longitude: -40.3089 },
    population: 4108508,
    area: 46074.447,
    timezone: 'America/Sao_Paulo',
    utcOffset: -3,
    iso: 'BR-ES'
  },
  GO: {
    uf: 'GO',
    name: 'Goiás',
    capital: 'Goiânia',
    region: 'Central-West',
    coordinates: { latitude: -15.827, longitude: -49.8362 },
    population: 7206589,
    area: 340242.854,
    timezone: 'America/Sao_Paulo',
    utcOffset: -3,
    iso: 'BR-GO'
  },
  MA: {
    uf: 'MA',
    name: 'Maranhão',
    capital: 'São Luís',
    region: 'Northeast',
    coordinates: { latitude: -4.9609, longitude: -45.2744 },
    population: 7153262,
    area: 329642.182,
    timezone: 'America/Fortaleza',
    utcOffset: -3,
    iso: 'BR-MA'
  },
  MT: {
    uf: 'MT',
    name: 'Mato Grosso',
    capital: 'Cuiabá',
    region: 'Central-West',
    coordinates: { latitude: -12.6819, longitude: -56.9211 },
    population: 3567234,
    area: 903207.050,
    timezone: 'America/Cuiaba',
    utcOffset: -4,
    iso: 'BR-MT'
  },
  MS: {
    uf: 'MS',
    name: 'Mato Grosso do Sul',
    capital: 'Campo Grande',
    region: 'Central-West',
    coordinates: { latitude: -20.7722, longitude: -54.7852 },
    population: 2839188,
    area: 357142.074,
    timezone: 'America/Campo_Grande',
    utcOffset: -4,
    iso: 'BR-MS'
  },
  MG: {
    uf: 'MG',
    name: 'Minas Gerais',
    capital: 'Belo Horizonte',
    region: 'Southeast',
    coordinates: { latitude: -18.5122, longitude: -44.555 },
    population: 21411923,
    area: 586521.121,
    timezone: 'America/Sao_Paulo',
    utcOffset: -3,
    iso: 'BR-MG'
  },
  PA: {
    uf: 'PA',
    name: 'Pará',
    capital: 'Belém',
    region: 'North',
    coordinates: { latitude: -3.1191, longitude: -52.9553 },
    population: 8777124,
    area: 1245870.707,
    timezone: 'America/Belem',
    utcOffset: -3,
    iso: 'BR-PA'
  },
  PB: {
    uf: 'PB',
    name: 'Paraíba',
    capital: 'João Pessoa',
    region: 'Northeast',
    coordinates: { latitude: -7.24, longitude: -36.782 },
    population: 4059905,
    area: 56467.239,
    timezone: 'America/Fortaleza',
    utcOffset: -3,
    iso: 'BR-PB'
  },
  PR: {
    uf: 'PR',
    name: 'Paraná',
    capital: 'Curitiba',
    region: 'South',
    coordinates: { latitude: -24.8936, longitude: -51.5528 },
    population: 11597484,
    area: 199307.922,
    timezone: 'America/Sao_Paulo',
    utcOffset: -3,
    iso: 'BR-PR'
  },
  PE: {
    uf: 'PE',
    name: 'Pernambuco',
    capital: 'Recife',
    region: 'Northeast',
    coordinates: { latitude: -8.8137, longitude: -36.9541 },
    population: 9674793,
    area: 98067.881,
    timezone: 'America/Recife',
    utcOffset: -3,
    iso: 'BR-PE'
  },
  PI: {
    uf: 'PI',
    name: 'Piauí',
    capital: 'Teresina',
    region: 'Northeast',
    coordinates: { latitude: -7.7183, longitude: -42.7289 },
    population: 3289290,
    area: 251755.485,
    timezone: 'America/Fortaleza',
    utcOffset: -3,
    iso: 'BR-PI'
  },
  RJ: {
    uf: 'RJ',
    name: 'Rio de Janeiro',
    capital: 'Rio de Janeiro',
    region: 'Southeast',
    coordinates: { latitude: -22.9068, longitude: -43.1729 },
    population: 17463349,
    area: 43750.426,
    timezone: 'America/Sao_Paulo',
    utcOffset: -3,
    iso: 'BR-RJ'
  },
  RN: {
    uf: 'RN',
    name: 'Rio Grande do Norte',
    capital: 'Natal',
    region: 'Northeast',
    coordinates: { latitude: -5.4026, longitude: -36.9541 },
    population: 3560903,
    area: 52809.602,
    timezone: 'America/Fortaleza',
    utcOffset: -3,
    iso: 'BR-RN'
  },
  RS: {
    uf: 'RS',
    name: 'Rio Grande do Sul',
    capital: 'Porto Alegre',
    region: 'South',
    coordinates: { latitude: -30.0346, longitude: -51.2177 },
    population: 11466630,
    area: 281707.151,
    timezone: 'America/Sao_Paulo',
    utcOffset: -3,
    iso: 'BR-RS'
  },
  RO: {
    uf: 'RO',
    name: 'Rondônia',
    capital: 'Porto Velho',
    region: 'North',
    coordinates: { latitude: -11.5057, longitude: -63.5806 },
    population: 1815278,
    area: 237765.347,
    timezone: 'America/Porto_Velho',
    utcOffset: -4,
    iso: 'BR-RO'
  },
  RR: {
    uf: 'RR',
    name: 'Roraima',
    capital: 'Boa Vista',
    region: 'North',
    coordinates: { latitude: 1.99, longitude: -61.33 },
    population: 652713,
    area: 224273.831,
    timezone: 'America/Boa_Vista',
    utcOffset: -4,
    iso: 'BR-RR'
  },
  SC: {
    uf: 'SC',
    name: 'Santa Catarina',
    capital: 'Florianópolis',
    region: 'South',
    coordinates: { latitude: -27.2423, longitude: -50.2189 },
    population: 7338473,
    area: 95730.921,
    timezone: 'America/Sao_Paulo',
    utcOffset: -3,
    iso: 'BR-SC'
  },
  SP: {
    uf: 'SP',
    name: 'São Paulo',
    capital: 'São Paulo',
    region: 'Southeast',
    coordinates: { latitude: -23.5505, longitude: -46.6333 },
    population: 46649132,
    area: 248219.485,
    timezone: 'America/Sao_Paulo',
    utcOffset: -3,
    iso: 'BR-SP'
  },
  SE: {
    uf: 'SE',
    name: 'Sergipe',
    capital: 'Aracaju',
    region: 'Northeast',
    coordinates: { latitude: -10.5741, longitude: -37.3857 },
    population: 2338474,
    area: 21938.188,
    timezone: 'America/Maceio',
    utcOffset: -3,
    iso: 'BR-SE'
  },
  TO: {
    uf: 'TO',
    name: 'Tocantins',
    capital: 'Palmas',
    region: 'North',
    coordinates: { latitude: -10.1753, longitude: -48.2982 },
    population: 1607363,
    area: 277423.627,
    timezone: 'America/Araguaina',
    utcOffset: -3,
    iso: 'BR-TO'
  }
};

/**
 * Get state data by UF code, optionally localized
 * 
 * @param uf - Brazilian state UF code (e.g., "SP", "RJ")
 * @param locale - Optional locale for localized state name (default: "en")
 * @returns State data object with all geographical and demographic information
 * 
 * @example
 * ```ts
 * const spData = getStateData('SP');
 * const spDataPT = getStateData('SP', 'pt-BR');
 * ```
 */
export function getStateData(uf: BRStateUF, locale?: Locale): BRStateData {
  const data = statesData[uf];
  if (!locale || locale === 'en') {
    return data;
  }
  return {
    ...data,
    name: getStateName(uf, locale)
  };
}

/**
 * Get all states by region
 * 
 * @param region - Brazilian region name (North, Northeast, Central-West, Southeast, South)
 * @returns Array of state data objects for all states in the specified region
 * 
 * @example
 * ```ts
 * const southStates = getStatesByRegion('South');
 * const northeastStates = getStatesByRegion('Northeast');
 * ```
 */
export function getStatesByRegion(region: BRStateData['region']): BRStateData[] {
  return Object.values(statesData).filter(state => state.region === region);
}

/**
 * Get all state UF codes
 * 
 * @returns Array of all 27 Brazilian state UF codes
 * 
 * @example
 * ```ts
 * const allUFs = getAllStateUFs();
 * // ['AC', 'AL', 'AP', 'AM', 'BA', 'CE', 'DF', ...]
 * ```
 */
export function getAllStateUFs(): BRStateUF[] {
  return Object.keys(statesData) as BRStateUF[];
}
